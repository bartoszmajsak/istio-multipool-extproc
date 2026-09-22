# Istio multi-pool ext_proc misassociation

Every `InferencePool` ships with its own endpoint picker - a small service the gateway asks,
once per request, "which replica should take this one?". That is the entire reason to use an
InferencePool. The picker knows which replica already has your prompt prefix cached and which
one is drowning.

So the gateway needs to ask the right pool's picker. There are two currently two issues in the 
Istio implementation where it seems it doesn't do the right thing.

**One rule, two pools.** The usual canary - 90/10 across two pools in a single route rule.
Istio attaches one picker per *rule*, not per backend, so one pool's picker answers for all
of it:

```
rule  ->  90% pool-a  \
                       >-- both ask pool-b's picker
          10% pool-b  /
```

**Two routes, one rule name.** Different services and different pools but the same rule name. 
Gateway API only asks that names be unique inside a single HTTPRoute, so reusing
them across routes seems perfectly legal. Istio keys each picker by that name and merges the
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
503s. Sampled while the rule was down, every status still read healthy.

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

Measured on 2026-09-11 using the same cluster, manifests and `proxyv2:1.30.4` image digest.
The patched control plane is `quay.io/bmajsak/pilot:1.30.4-fix-61594-v2`, which carries
[#61601](https://github.com/istio/istio/pull/61601) on top of 1.30.4, including the review
changes made to that PR. Install it with the `--istiod-image` invocation below.

For the weighted rule, split 9:1, pool B was scaled to zero:

| Control plane | Failures with pool B empty |
|---|---|
| Stock Istio 1.30.4 | **164/164**, including healthy pool A |
| Stock + EnvoyFilter | **5/100**, all pool B |
| Patched image | **12/164**, all pool B |

The stock and patched counts cover requests sampled during the drained window, so the
patched figure moves run to run with how the drain lines up - 12 and 23 across two runs of
the same image. What holds in every run is the attribution: none of the failures belonged
to healthy pool A. The EnvoyFilter count comes from a separate 100-request burst. The
concurrent A-only control stayed healthy in every full run. See the [stock results](results/istio-1.30.4/validate.out)
and [patched results](results/istio-1.30.4+pilot-1.30.4-fix-61594-v2/validate.out).

The collision routes each reference only their own pool. They share no backendRefs;
they share the rule name `v1-completions-path`:

| Route | Stock Istio 1.30.4 | Patched image |
|---|---|---|
| `collide-a` → pool A | Served by A, **picked by B** | Served by A, picked by A |
| `collide-b` → pool B | Served by B, picked by B | Served by B, picked by B |

These additional probes sent 100 requests per route per image, all returning 200. On the
patched image, every request reached exactly the endpoint its own picker selected. The
weighted route also passed 100 such probes, giving 300/300 exact endpoint matches across
the three routes. `validate.sh` does not exercise the collision routes, and their behavior
during a pool outage was not tested.

`validate.sh` is a reproducer: its assertions expect the defect. The stock run exited 0;
the patched run exited 7 because the defect was absent. The per-request checks above
independently verified the corrected behavior. Expectation modes that would let one runner
both reproduce and accept a fix do not exist yet.

## How to run it

```bash
./setup.sh                                            # kind + Istio + CRDs + workloads, ~45s
./validate.sh                                         # the scenarios below, ~2 min
./validate.sh --verbose                               # plus the evidence each step rests on

./setup.sh --istio-version 1.29.7                     # another minor, same cluster
./setup.sh --istiod-image quay.io/bmajsak/pilot:1.30.4-fix-61594-v2   # a candidate control plane
```

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
the rule inherits one pool's picker *and* one pool's failure semantics. Both pools here declare
`FailClose`, so this spike shows the field being taken from one of them rather than a pool
being flipped: a mixed pair would be needed to demonstrate a `FailClose` pool running open.

### Two routes, one rule name

`collide-a` and `collide-b` share no `backendRef`s and carry no weights. What they share is a
rule name, which Gateway API only requires to be unique within a single HTTPRoute - so this
is valid, and it is what a controller emitting a fixed set of rule names produces for every
service it manages. Istio keys the per-rule picker config by that name and merges the map
across every route on the gateway, so the two entries collide while the matches stay distinct.

This shape has no weighted split and therefore no round-robin fallback to soften it: a wrong
picker is simply a wrong picker.

## Inspecting a live cluster

Small pieces, usable on any cluster, not just this one.

**One report for the whole gateway.** Wraps everything below - status, the EnvoyFilters
touching it, the filter chain, the picker each route got, and a verdict:

```bash
./scripts/check-gateway-ext-proc.sh <gateway-name> [namespace]
```

On a control plane carrying the defect:

```
Detection:
  PROBLEM: 1 route(s) span several pools under a single route-level picker
    - multipool-spike.split.0  pools=pool-a...,pool-b...  picker=epp-b...
  PROBLEM: 2 route(s) share a rule name and carry the same picker for different pools
    - v1-completions-path  pool=pool-a...  picker=epp-b...
    - v1-completions-path  pool=pool-b...  picker=epp-b...
  EPP mappings:
    - epp-a...  -> pool-a...
    - epp-b...  -> pool-a...        <- epp-b serving two pools is the fault
                -> pool-b...
```

Once the pickers are right - either patched, or on a fixed control plane:

```
Detection:
  OK: all 4 InferencePool-backed route(s) have a picker matching their own pool
  EPP mappings:
    - epp-a...  -> pool-a...
    - epp-b...  -> pool-b...
```

An EPP appearing against more than one pool in that mapping is the fault in one line. The
verdict judges only the route that actually serves each path: Envoy takes the first match, so
a shadowed duplicate left behind by the workaround is not a finding.

The rest of this section is what the script runs, for when you want one piece on its own.

**Find the gateway pod.**

```bash
kubectl get pods -A -l gateway.networking.k8s.io/gateway-name \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name' --no-headers
```

**Which picker each pool is supposed to get.** Istio synthesises a headless Service per
InferencePool and labels it with the pool's endpoint picker. This is the intended mapping,
before any routing is involved:

```bash
kubectl get svc -A -l istio.io/inferencepool-name \
  -o custom-columns='NS:.metadata.namespace,POOL:.metadata.labels.istio\.io/inferencepool-name,EPP:.metadata.labels.istio\.io/inferencepool-extension-service' --no-headers
```

**Grab the config the gateway is actually running.**

```bash
kubectl exec -n <ns> <gateway-pod> -c istio-proxy -- \
  pilot-agent request GET config_dump > dump.json
```

**Which picker each route actually got.** One line per InferencePool-backed route, with the
pools it sends to and the picker attached at route level and per weighted cluster:

```bash
jq -r '
def short: if . == null then "-" else ((split("||")[1] // .) | split(".")[0]) end;
def epp(o): (o."envoy.filters.http.ext_proc" // null)
  | if . == null then "NONE"
    elif .overrides.grpc_service.envoy_grpc.cluster_name then (.overrides.grpc_service.envoy_grpc.cluster_name | short)
    elif .disabled then "disabled"
    else "present" end;
[ .configs[]
  | select(."@type" | test("RoutesConfigDump"))
  | (.dynamic_route_configs[]?.route_config, .static_route_configs[]?.route_config)
  | .virtual_hosts[]? | .routes[]?
  | { match: (.match.path // .match.prefix // .match.path_separated_prefix // "?"),
      backends: ([.route.cluster] + [.route.weighted_clusters.clusters[]?.name]
                 | map(select(. != null) | short) | join(",")),
      route_epp: epp(.typed_per_filter_config // {}),
      cluster_epp: ([.route.weighted_clusters.clusters[]? | epp(.typed_per_filter_config // {})] | join(",")) }
  | select(.backends | test("-ip-|inference|pool"))
]
| .[] | "\(.match)\t\(.backends)\troute-epp=\(.route_epp)\tcluster-epp=\(if .cluster_epp == "" then "-" else .cluster_epp end)"
' dump.json | column -t -s$'\t'
```

Reading the output:

| what you see | what it means |
|---|---|
| `route-epp=NONE` on a pool-backed route | no picker attached at all - the EPP is never called and logs nothing |
| one `route-epp` against two different pools | two routes share a rule name, one stole the other's picker |
| two pools in `backends`, one `route-epp`, `cluster-epp=NONE,NONE` | one picker scores the whole rule |
| each pool paired with its own `cluster-epp` | fixed build, per-backend pickers |

**Why a wrong picker is silent.** Each pool cluster load balances with `override_host`,
which reads the endpoint the picker named and *skips it when it is not a member of that
cluster*, falling through to the policy below. That fallback is what keeps the requests
succeeding:

```bash
kubectl exec -n <ns> <gateway-pod> -c istio-proxy -- \
  curl -s 'localhost:15000/config_dump?resource=dynamic_active_clusters' \
| jq -r '.configs[].cluster | select(.name | test("-ip-")) |
  "\(.name | split("||")[1] | split(".")[0])  lb=\(.lb_policy)  policy=\(
     .load_balancing_policy.policies[0].typed_extension_config.name // "-" | split(".") | last)  fallback=\(
     .load_balancing_policy.policies[0].typed_extension_config.typed_config.fallback_policy.policies[0].typed_extension_config.name // "-" | split(".") | last)"'
```

```
pool-a-ip-8934303d  lb=CLUSTER_PROVIDED  policy=override_host  fallback=round_robin
pool-b-ip-574c3c50  lb=CLUSTER_PROVIDED  policy=override_host  fallback=round_robin
```

**Which endpoints each pool actually holds.** The sets are disjoint, which is why an endpoint
named by another pool's picker is never a member and always falls through:

```bash
kubectl exec -n <ns> <gateway-pod> -c istio-proxy -- \
  curl -s 'localhost:15000/clusters?format=json' \
| jq -r '.cluster_statuses[] | select(.name | test("-ip-")) |
  "\(.name | split("||")[1] | split(".")[0])  \([.host_statuses[]?.address.socket_address.address] | sort | join(" "))"'
```

```
pool-a-ip-8934303d  10.244.0.6 10.244.0.7 10.244.0.8
pool-b-ip-574c3c50  10.244.0.9 10.244.0.10 10.244.0.11
```

Put together: the picker names an address, the cluster it was routed to does not contain it,
`override_host` drops it, round robin answers instead. Status codes and the weighted split
stay correct, so nothing downstream reports the loss.

**How many ext_proc filters are in the chain.** Relevant when something else also inserts
ext_proc stages - the listener-level EPP filter is a placeholder (`cluster_name: dummy`) and
only does anything when a route overrides it:

```bash
jq -r '
  .configs[] | select(."@type" | test("ListenersConfigDump"))
  | .dynamic_listeners[]?.active_state.listener as $l
  | $l.filter_chains[]?.filters[]?
  | select(.name == "envoy.filters.network.http_connection_manager")
  | .typed_config.http_filters[]? | select((.name // "") | contains("ext_proc"))
  | [$l.name, .name,
     (.typed_config.grpc_service.envoy_grpc.cluster_name // "per-route"),
     (.typed_config.processing_mode.request_body_mode // "default")]
  | @tsv' dump.json | sort -u | column -t -s$'\t'
```

## Cluster verification

To see if your cluster setup still carries the bug, you can invoke the following commands:

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

One picker name against two different pools is the core issue.

## Consequences

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
- **Not measured here.** The scenarios never reorder backendRefs, set a weight to zero, or
  pair a `FailOpen` pool with a `FailClose` one, so those consequences are read from the code
  above rather than demonstrated. Status is sampled once during the weighted outage, which
  says the conditions were green at that moment, not that they never went red.
- **A mixed `[InferencePool, Service]` rule is affected by the same overwrite** - a Service
  backendRef yields a nil config and `route_collections.go:103` gates ext_proc on it for the
  whole rule. Separate defect, not covered here.

## Workaround

One `EnvoyFilter` covers both scenarios. `INSERT_BEFORE` on `HTTP_ROUTE` in both cases:
`REPLACE` does not exist for `HTTP_ROUTE` and `MERGE` appends to the repeated `clusters`
field. What gets inserted differs by shape.

```bash
./render-envoyfilter.sh            # writes results/istio-<version>/envoyfilter-per-pool-extproc.yaml
./render-envoyfilter.sh --print    # to stdout
kubectl apply -f results/istio-<version>/envoyfilter-per-pool-extproc.yaml
```

**One rule, two pools.** The inserted copy drops the route-level override and puts an
`ExtProcPerRoute` on each weighted cluster naming that pool's own picker. A backend that is
not an InferencePool gets `disabled`, so no picker claims traffic belonging to no pool. This
restores per-pool correlation and reduces the outage to the emptied member's weight share.

**Two routes, one rule name.** The inserted copy keeps its single backend and only swaps the
picker for the one its own pool owns. The patch cannot select between the two routes by name,
because sharing a name is the defect - `routeConfiguration.vhost.route.name` is the only
selector `EnvoyFilter` offers. Instead the corrected route is inserted ahead of both, carrying
its own path match, and Envoy's first-match-wins ordering does the disambiguation. The
original stays in the table, shadowed for that path.

Only routes actually carrying the wrong picker are patched, so a collision where the loser
happens to already hold its own picker produces nothing.

Generated rather than checked in, because the pool cluster names embed a hash Istio derives
per InferencePool. It reads the gateway's route table, finds both shapes, and maps each pool
cluster to its picker using the labels Istio puts on the Service it synthesises per pool
(`istio.io/inferencepool-extension-service`).

Verify it took by re-reading the route table - the corrected copies sort ahead of the
originals:

```
ord path                      route-epp  cluster-epp
  0  /weighted-two-pools-test   -          ['epp-a', 'epp-b']   <- inserted
  1  /weighted-two-pools-test   epp-b      ['-', '-']           <- original, shadowed
  2  /collide-a                 epp-a      []                   <- inserted
  3  /collide-a                 epp-b      []                   <- original, shadowed
```

> [!IMPORTANT]
> Not production-viable: cluster names embed Istio-generated hashes, it is per-route and
> hand-maintained, and EnvoyFilter has no status reporting when it stops matching. The
> collision patches additionally depend on each colliding route having a distinct path match
> to key on, and on their relative order being safe to front-run - a table with catch-alls
> needs checking by hand.

## References

- [Endpoint Picker Protocol](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/docs/proposals/004-endpoint-picker-protocol/README.md)
- [`GatewayWeightedAcrossTwoInferencePools`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/conformance/tests/gateway_weighted_two_pools.go)
- [`ExtProcPerRoute`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto#envoy-v3-api-msg-extensions-filters-http-ext-proc-v3-extprocperroute)
- [`OverrideHost` LB policy](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/load_balancing_policies/override_host/v3/override_host.proto)
- [istio#58392](https://github.com/istio/istio/issues/58392) / [#58393](https://github.com/istio/istio/pull/58393) - merged routes dropped later routes' picker config
- [istio#61594](https://github.com/istio/istio/issues/61594) - one rule, several pools, one picker
- [istio#61601](https://github.com/istio/istio/pull/61601) - resolves pickers per backendRef; verified against both shapes above
