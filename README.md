# Istio multi-pool ext_proc misassociation

Every `InferencePool` ships with its own endpoint picker - a small service the gateway asks,
once per request, "which replica should take this one?". That is the entire reason to use an
InferencePool. The picker knows which replica already has your prompt prefix cached and which
one is drowning.

So the gateway needs to ask the right pool's picker. There are two fairly ordinary ways it
doesn't.

**One rule, two pools.** The usual canary - 90/10 across two pools in a single route rule.
Istio attaches one picker per *rule*, not per backend, so one pool's picker answers for all
of it:

```
rule  ->  90% pool-a  \
                       >-- both ask pool-b's picker
          10% pool-b  /
```

**Two routes, one rule name.** Different services, different pools, nothing shared - except a
rule name. Gateway API only asks that names be unique inside a single HTTPRoute, so reusing
them across routes is perfectly legal. Istio keys each picker by that name and merges the
routes, and whichever lands last takes the name, along with the other service's picker:

```
route-a  rule "v1-completions-path"  ->  pool-a  \
                                                  >-- one entry survives
route-b  rule "v1-completions-path"  ->  pool-b  /
```

The annoying part is that while both pools are healthy, none of this shows. The wrong picker
names an endpoint that isn't in the cluster Envoy selected, so Envoy ignores it and
round-robins instead, and the right pod answers anyway. 200s all round, split matches the
weights. You have only lost the picking, which was the point of the thing.

It gets loud when the picker that won has nothing to pick from - canary still pulling its
model, member scaled to zero, mid rolling update. It then rejects every request it is asked
about, including all the traffic headed for the entirely healthy pool, and the whole rule
503s. Status stays green throughout, naturally.

Reproduced on Istio 1.29.7, 1.30.2 and 1.30.4 (Envoy 1.37.6-dev, 1.38.3-dev, 1.38.4-dev).

## Reproducer

- A failing case for each shape, on a kind cluster, in about three minutes.
- A pass/fail signal per request - the endpoint the picker chose against the pool that
  actually served - so a fix is confirmed rather than assumed.
- A way to run a candidate control plane against both without touching anything else:
  `--istiod-image` swaps istiod alone and leaves the gateway on the released proxy.
- An EnvoyFilter that restores per-pool picking on an unfixed build, generated from the
  gateway's own route table.

## Verification

Reproducer is using the same cluster, same manifests, same `proxyv2:1.30.4`. istiod is the piece that is changed to demonstrate that fix works.

| Route | Shape | Istio 1.30.4 | [#61601](https://github.com/istio/istio/pull/61601) |
|---|---|---|---|
| `collide-a` | two HTTPRoutes reusing one rule name | served pool-a, **picked by pool-b** | picked by pool-a |
| `collide-b` | the other half of that pair | pool-b | pool-b |
| `split` | one rule, two weighted pools | picker A invoked 0 of 100 | 35 a / 5 b, each by its own picker |

Every request returned 200 in both columns. Nothing about the responses says which one you
are looking at, which is the point.

The right-hand column is `quay.io/bmajsak/pilot:1.30.4-fix-61594`, which carries the change
in #61601 on top of 1.30.4. Reproduce it with the `--istiod-image` invocation below.

## Run it

```bash
./setup.sh                                            # kind + Istio + CRDs + workloads, ~45s
./validate.sh                                         # the scenarios below, ~2 min
./validate.sh --verbose                               # plus the evidence each step rests on

./setup.sh --istio-version 1.29.7                     # another minor, same cluster
./setup.sh --istiod-image quay.io/bmajsak/pilot:1.30.4-fix-61594   # a candidate control plane
```

`--istiod-image` takes a registry reference or a locally built image, pulling once if it is
not already local and side-loading it either way, so a run does not depend on the cluster
reaching a registry.

It sets the image through the istiod chart's own `image` value, which names that container
and nothing else. `global.hub`/`global.tag` would also name the proxy image istiod hands to
the gateway, and only pilot is being replaced - the gateway keeps the released proxy, so a
comparison differs by the control plane alone. Going through the chart also leaves the field
owned by helm, so a second run upgrades over the first instead of conflicting with it.

To build one from an Istio checkout instead:

```bash
HUB=localhost TAG=mine BUILD_WITH_CONTAINER=0 make docker.pilot   # ~35s, istiod only
./setup.sh --istiod-image localhost/pilot:mine
```

`./validate.sh` prints its results and nothing else:

```
  1. two InferencePools behind one HTTPRoute rule, split 9:1, both healthy
     pool-b's picker chose the endpoint for 100 of 100 requests, pool-a's for 0
     each pool's picker should choose for its own share, so 90 and 10
  2. pool-b (the 10% canary) scaled to zero, as during a rollout
     163 of 163 requests on the rule failed over 10.9s, 89% of them bound for healthy pool-a
     only pool-b's own 10% share should have failed, so about 16
  3. same outage, with an EnvoyFilter giving each pool its own picker
     9 of 100 requests failed - pool-b's share only, pool-a served throughout
     which is what emptying a 10% member should cost
```

Assertions are silent unless they fail; the run exits non-zero if any does. Raw results and
image digests per run land in `results/istio-<version>/`.

## Two failure scenarios

### One rule, several pools

`[pool-a weight 9, pool-b weight 1]`, both `InferencePool`, each with its own picker. The
compiled route carries a single route-level override:

```json
"typed_per_filter_config": {
  "envoy.filters.http.ext_proc": {
    "overrides": {
      "grpc_service": { "envoy_grpc": { "cluster_name": "outbound|9002||epp-b..." } },
      "failure_mode_allow": false } } }
```

Neither `ClusterWeight` carries `typed_per_filter_config`. Note `failure_mode_allow` as well:
the rule inherits one pool's picker *and* one pool's failure semantics, so a pool declaring
`FailClose` runs `FailOpen` because another pool in the same rule said so.

### Two routes, one rule name

`collide-a` and `collide-b` share no backendRefs and carry no weights. What they share is a
rule name, which Gateway API only requires to be unique within a single HTTPRoute - so this
is valid, and it is what a controller emitting a fixed set of rule names produces for every
service it manages. Istio keys the per-rule picker config by that name and merges the map
across every route on the gateway, so the two entries collide while the matches stay distinct.

This shape has no weighted split and therefore no round-robin fallback to soften it: a wrong
picker is simply a wrong picker.

## Is your own cluster affected?

```bash
kubectl exec -n <ns> <gateway-pod> -c istio-proxy -- \
  curl -s 'localhost:15000/config_dump?resource=dynamic_route_configs' > rc.json
```

**One rule, two pools.** Lists any weighted rule whose picker sits at route level with none on
its clusters - one picker for the whole rule:

```bash
jq -r '[.configs[].route_config.virtual_hosts[]?.routes[]?
  | select(.route.weighted_clusters)
  | {rule: .name,
     route_picker: (.typed_per_filter_config."envoy.filters.http.ext_proc".overrides.grpc_service.envoy_grpc.cluster_name // null),
     per_cluster: [.route.weighted_clusters.clusters[] | .typed_per_filter_config."envoy.filters.http.ext_proc" != null]}
  | select(.route_picker != null and (.per_cluster | any | not))
] | if length == 0 then "none" else .[] | .rule end' rc.json
```

**Two routes, one rule name.** Lists rule names used more than once, with the pool and the
picker each one got. Different pools showing the *same* picker is the collision:

```bash
jq -r '[.configs[].route_config.virtual_hosts[]?.routes[]?
  | select(.route.cluster != null and (.route.cluster | test("-ip-")))
  | {rule: .name,
     pool:   (.route.cluster | split("||")[1] // .route.cluster),
     picker: (.typed_per_filter_config."envoy.filters.http.ext_proc".overrides.grpc_service.envoy_grpc.cluster_name // "none" | split("||")[1] // .)}]
  | group_by(.rule) | map(select(length > 1))
  | if length == 0 then ["no repeated rule names"] else
      .[] | .[] | "\(.rule)  pool=\(.pool)  picker=\(.picker)" end' rc.json
```

On a fixed build the first prints `none` and the second pairs each pool with its own picker:

```
v1-completions-path  pool=pool-a-ip-8934303d...  picker=epp-a...
v1-completions-path  pool=pool-b-ip-574c3c50...  picker=epp-b...
```

One picker name against two different pools is the bug.

## Why

Source at istio/istio `b1c58947`.

| Fact | Where |
|---|---|
| `ExtProcPerRoute` is only ever constructed at route level | `route.go:514-521`, the sole non-test construction |
| `ClusterWeight` never gets `TypedPerFilterConfig` | `processWeightedDestination`, `route.go:747` |
| Picker is the last backendRef processed, unguarded overwrite | `conversion.go:1008` (`ipCfg = ipconfig`) |
| Zero-weight refs pruned before that loop | `conversion.go:993` |
| Merged routes overwrite by rule name | `route_collections.go:869` |

Consequences:

- **The winner is the last non-zero-weight backendRef.** Reordering backendRefs changes which
  picker runs, and `weight: 0` removes a member from contention, so ownership moves during a
  rollback to 0.
- **Endpoint selection is discarded for the majority share.** The picker returns an endpoint
  from its own pool; that host is not in the selected cluster; `override_host` falls back to
  round robin. Load-aware routing is inoperative for traffic not bound to the picker's own
  pool, with no error.
- **One empty member fails the whole rule.** A picker with no ready endpoints must return
  `ImmediateResponse` 503 ([EPP protocol](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/docs/proposals/004-endpoint-picker-protocol/README.md)).
  It does so for every request on the rule, so emptying the 10% member costs 100% of the
  rule's traffic. Under the workaround below the same empty pool costs 10%.
- **Not caught by conformance.** `GatewayWeightedAcrossTwoInferencePools` scores the answering
  pod and the weight split. The round-robin fallback keeps both correct.
- **A mixed `[InferencePool, Service]` rule is affected by the same overwrite** - a Service
  backendRef yields a nil config and `route_collections.go:103` gates ext_proc on it for the
  whole rule. Separate defect, not covered here.

## Workaround for an unfixed build

An EnvoyFilter placing an `ExtProcPerRoute` on each weighted cluster, naming that pool's
picker. `INSERT_BEFORE` on `HTTP_ROUTE`: `REPLACE` does not exist for `HTTP_ROUTE` and `MERGE`
appends to the repeated `clusters` field. It restores per-pool correlation and reduces the
outage to the emptied member's weight share.

```bash
./render-envoyfilter.sh            # writes results/istio-<version>/envoyfilter-per-pool-extproc.yaml
./render-envoyfilter.sh --print    # to stdout
```

Generated rather than checked in, because the pool cluster names embed a hash Istio derives
per InferencePool. It reads the gateway's route table, finds every route splitting across two
or more InferencePools under a single route-level override, and maps each pool cluster to its
picker using the labels Istio puts on the Service it synthesises per pool
(`istio.io/inferencepool-extension-service`). Nothing is keyed on naming, so it works against
routes emitted by another controller - pointed at a KServe LLMInferenceService gateway it
found 29 affected routes and mapped both pools without changes.

> [!IMPORTANT]
> Not production-viable: cluster names embed Istio-generated hashes, it is per-route and
> hand-maintained, and EnvoyFilter has no status reporting when it stops matching.

## Components and gotchas

Real components throughout: `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0`, Gateway API
conformance's `echo-basic`, `grafana/k6:2.2.0`. Gateway Service is ClusterIP and traffic
originates in-cluster: no MetalLB, no port-forward.

Two picker requirements, neither failure naming its cause:

- `--secure-serving` defaults to true. Istio dials plaintext h2c, so leaving it enabled
  returns `ext_proc_error_gRPC_error_14 ... connection_termination` (500) on every request.
- The picker selects a body parser by path suffix. `/a-only` returns
  `no parser registered matching path suffix` (400). Paths end `/v1/completions`.

## References

- [Endpoint Picker Protocol](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/docs/proposals/004-endpoint-picker-protocol/README.md)
- [`GatewayWeightedAcrossTwoInferencePools`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/conformance/tests/gateway_weighted_two_pools.go)
- [`ExtProcPerRoute`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto#envoy-v3-api-msg-extensions-filters-http-ext-proc-v3-extprocperroute)
- [`OverrideHost` LB policy](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/load_balancing_policies/override_host/v3/override_host.proto)
- [istio#58392](https://github.com/istio/istio/issues/58392) / [#58393](https://github.com/istio/istio/pull/58393) - merged routes dropped later routes' picker config
- [istio#61594](https://github.com/istio/istio/issues/61594) - one rule, several pools, one picker
- [istio#61601](https://github.com/istio/istio/pull/61601) - resolves pickers per backendRef; verified against both shapes above
