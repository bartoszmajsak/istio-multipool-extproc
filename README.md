# Istio multi-pool ext_proc misassociation

One HTTPRoute rule with two InferencePool backendRefs gets one endpoint picker. The other
pool's picker is never invoked. When the pool that owns the picker has no ready endpoints,
the whole rule returns 503 and takes the entire traffic down.

Reproduced on Istio 1.29.7, 1.30.2 and 1.30.4 (Envoy 1.37.6-dev, 1.38.3-dev, 1.38.4-dev).

## Observation

Rule: `[pool-a weight 9, pool-b weight 1]`, both `InferencePool`, each with its own endpoint
picker. Compiled route from `config_dump?resource=dynamic_route_configs`:

```json
{
  "name": "multipool-spike.split.0",
  "route": { "weighted_clusters": { "clusters": [
      { "name": "outbound|54321||pool-a-ip-8934303d...", "weight": 9 },
      { "name": "outbound|54321||pool-b-ip-574c3c50...", "weight": 1 } ] } },
  "typed_per_filter_config": {
    "envoy.filters.http.ext_proc": {
      "@type": "...ext_proc.v3.ExtProcPerRoute",
      "overrides": {
        "grpc_service": { "envoy_grpc": { "cluster_name": "outbound|9002||epp-b..." } },
        "failure_mode_allow": false } } }
}
```

Verifiable without this harness, against any cluster with the route applied:

```bash
kubectl exec -n <ns> <gateway-pod> -c istio-proxy -- \
  curl -s localhost:15000/config_dump?resource=dynamic_route_configs \
| jq -r '.configs[].route_config.virtual_hosts[].routes[]
    | select(.route.weighted_clusters)
    | {route: .name,
       route_level_picker: (.typed_per_filter_config."envoy.filters.http.ext_proc"
                            .overrides.grpc_service.envoy_grpc.cluster_name // "none"),
       per_cluster: [.route.weighted_clusters.clusters[]
                     | {cluster: (.name|split("||")[1]|split(".")[0]), weight,
                        picker: (.typed_per_filter_config."envoy.filters.http.ext_proc" // "none")}]}'
```

```json
{
  "route": "multipool-spike.split.0",
  "route_level_picker": "outbound|9002||epp-b.multipool-spike.svc.cluster.local",
  "per_cluster": [
    { "cluster": "pool-a-ip-8934303d", "weight": 9, "picker": "none" },
    { "cluster": "pool-b-ip-574c3c50", "weight": 1, "picker": "none" }
  ]
}
```

- One `ExtProcPerRoute`, at route level, naming `epp-b` only.
- Neither `ClusterWeight` carries `typed_per_filter_config`.
- 100 requests: pool B's picker chose the endpoint for all 100. Pool A's picker for 0, while
  answering 100 on its own single-pool route in the same burst.
- 85 of 100 were served by a pool A pod while pool B's picker chose their endpoint.
- All 200. Weight split within band of 9:1.

```
1788529724098 split 200 backend-a-679d48bf78-s2n87 10.244.0.20:3000 bypass...-split-0
                        ^ answered by pool A       ^ picker chose this, a pool B endpoint
```

Envoy's access log, for requests whose `upstream_cluster` is pool A's:
`ep_requested` is a pool B endpoint, `upstream_host` a pool A one.

With pool B scaled to zero, all 100 requests return 503; 84 of them had already been routed
to pool A's cluster:

```
response_code 503   response_flags -   upstream_host null   upstream_cluster ...pool-a-ip-...
```

Gateway `Programmed`, HTTPRoute `Accepted`, both InferencePools `Accepted` remain `True`
throughout, asserted during the outage window.

## Reasons and consequences

Source at istio/istio `b1c58947`.

| Fact | Where |
|---|---|
| `ExtProcPerRoute` is only ever constructed at route level | `route.go:514-521`, the sole non-test construction |
| `ClusterWeight` never gets `TypedPerFilterConfig` | `processWeightedDestination`, `route.go:747` |
| Picker is the last backendRef processed, unguarded overwrite | `conversion.go:1008` (`ipCfg = ipconfig`) |
| Zero-weight refs pruned before that loop | `conversion.go:993` |

Consequences:

- **The winner is the last non-zero-weight backendRef** (from `conversion.go:1008` and
  `:993`; not exercised by the suite). Reordering backendRefs changes which picker runs, and
  `weight: 0` removes a member from contention, so ownership moves during a rollback to 0.
- **Endpoint selection is discarded for the majority share.** The picker returns an endpoint
  from its own pool; that host is not in the selected cluster; `override_host` falls back to
  round robin. Load-aware routing is inoperative for traffic not bound to the picker's own
  pool, with no error.
- **One empty member fails the whole rule.** A picker with no ready endpoints must return
  `ImmediateResponse` 503 ([EPP protocol](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/docs/proposals/004-endpoint-picker-protocol/README.md)).
  It does so for every request on the rule, so emptying the 10% member costs 100% of the
  rule's traffic. Under the workaround below the same empty pool costs 10%.

- **Not caught by conformance.** `GatewayWeightedAcrossTwoInferencePools` scores the
  answering pod and the weight split. The round-robin fallback keeps both correct. Not run
  here; assessed from the test source.
- **A mixed `[InferencePool, Service]` rule is affected by the same overwrite** - a Service
  backendRef yields a nil config and `route_collections.go:103` gates ext_proc on it for the
  whole rule. Separate defect, not covered by this reproducer.

## Reproducer

```bash
./setup.sh                         # kind + Istio + CRDs + workloads, ~45s
./validate.sh                      # the three steps below, ~2 min
./validate.sh --verbose            # plus the evidence each step rests on
./setup.sh --istio-version 1.29.7  # another minor, same cluster
```

`./validate.sh` prints three results and nothing else:

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

`--verbose` adds the compiled route table, the per-request counts, the failed
responses with their Envoy access-log fields, and the outage window. Assertions
are silent unless they fail; the run exits non-zero if any does.

Step 3's EnvoyFilter is generated from the route table rather than checked in, because the
pool cluster names embed a hash Istio derives from each InferencePool. To produce it without
running the scenario:

```bash
./render-envoyfilter.sh            # writes results/istio-<version>/envoyfilter-per-pool-extproc.yaml
./render-envoyfilter.sh --print    # to stdout
```

It reads the gateway's own route table, finds every route splitting across two or more
InferencePools under a single route-level override, and maps each pool cluster to its picker
using the labels Istio puts on the Service it synthesises per pool
(`istio.io/inferencepool-extension-service`). Nothing is keyed on naming, so it works against
routes emitted by another controller - pointed at a KServe LLMInferenceService gateway it
found 29 affected routes and mapped both pools without changes.

k6 asserts the correlation per route:

```
✗ [split]  endpoint chosen by the pool that served it   ↳ 15% — ✓ 15 / ✗ 85
✓ [a-only] endpoint chosen by the pool that served it
```

Step 3 is what rules out "requests failed because pods were removed": same empty pool, same
traffic, one config difference.

The outage step drives a continuous probe across the drain and the refill rather than
sampling a burst, so it reports the window - how long the rule was down, when the first
failure landed relative to Envoy seeing zero endpoints, and that the rule recovers on its
own.

Real components throughout: `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0`, Gateway API
conformance's `echo-basic`, `grafana/k6:2.2.0`. Results and image digests per run in
`results/istio-<version>/`. Gateway Service is ClusterIP, traffic originates in-cluster: no
MetalLB, no port-forward.

Two picker requirements, neither failure naming its cause:

- `--secure-serving` defaults to true. Istio dials plaintext h2c, so leaving it enabled
  returns `ext_proc_error_gRPC_error_14 ... connection_termination` (500) on every request.
- The picker selects a body parser by path suffix. `/a-only` returns
  `no parser registered matching path suffix` (400). Paths end `/v1/completions`.

## Potential workaround

An EnvoyFilter placing an `ExtProcPerRoute` on each weighted cluster, naming that pool's
picker (`INSERT_BEFORE` on `HTTP_ROUTE`; `REPLACE` does not exist for `HTTP_ROUTE` and
`MERGE` appends to the repeated `clusters` field). Restores per-pool correlation and reduces
the outage to the emptied member's weight share.

### How the patch is generated

`render-envoyfilter.sh` was created to work around the issue. It:

1. Reads the gateway's route table (`config_dump?resource=dynamic_route_configs`) and finds
   every route that splits across two or more InferencePools under one route-level override -
   the shape this defect produces, not a specific route name.
2. Maps each pool's weighted cluster to its picker's cluster from the labels Istio itself
   attaches to the Service it synthesises per InferencePool
   (`istio.io/inferencepool-extension-service`, `-extension-port`). No naming convention is
   assumed, so the same script identifies the affected routes on a KServe
   LLMInferenceService gateway - 29 of them there, in one pass.
3. Copies the compiled route's `overrides` object **whole**, and changes exactly one field
   in the copy: `grpc_service.envoy_grpc.cluster_name`, to that pool's own picker.

> [!IMPORTANT]
> Not production-viable: cluster names embed Istio-generated hashes, it is per-route and
hand-maintained, and EnvoyFilter has no status reporting when it stops matching.

A fix would attach `ext_proc` config per backendRef rather than once per rule.

## References

- [Endpoint Picker Protocol](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/docs/proposals/004-endpoint-picker-protocol/README.md)
- [`GatewayWeightedAcrossTwoInferencePools`](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/conformance/tests/gateway_weighted_two_pools.go)
- [`ExtProcPerRoute`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto#envoy-v3-api-msg-extensions-filters-http-ext-proc-v3-extprocperroute)
- [`OverrideHost` LB policy](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/load_balancing_policies/override_host/v3/override_host.proto)
