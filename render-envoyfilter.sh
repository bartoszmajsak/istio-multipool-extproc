#!/usr/bin/env bash
# Renders the fix scenario's EnvoyFilter: one ExtProcPerRoute per weighted
# cluster, each naming its own pool's picker.
#
#   ./render-envoyfilter.sh [--print]
#
# Nothing here is specific to this spike's naming. Routes are discovered from the
# gateway's own route table, and the pool-to-picker mapping is read from the
# labels Istio puts on the Service it synthesises per InferencePool:
#
#   internal.istio.io/service-semantics:      inferencepool
#   istio.io/inferencepool-name:              <pool>
#   istio.io/inferencepool-extension-service: <picker service>
#   istio.io/inferencepool-extension-port:    <picker port>
#
# So a KServe LLMInferenceService route - arbitrary rule names, "*:80" vhost,
# a "<name>-inference-pool" pool paired with a "<name>-epp-service" picker - is
# handled without knowing any of that.
#
# The patched route is derived from the route Envoy is running, never written by
# hand. It is inserted before the original and shadows it: Istio's HTTP_ROUTE
# patching has no REPLACE and applies all removes before all adds, so the
# original cannot be swapped out in one pass. A new route must therefore carry
# the original's match, rewrite, timeout, retry policy and
# cluster_not_found_response_code, or the scenario measures a different route and
# calls the difference a fix.
#
# Exactly three things change, and validate.sh asserts that:
#
#   1. name                   -> "<original>.fixed", so %ROUTE_NAME% says which
#                                route served and the insert has its own anchor
#   2. route-level ext_proc   -> removed
#   3. each weighted cluster  -> Istio's own override copied whole, with only
#                                grpc_service.envoy_grpc.cluster_name replaced
#
# Rule 3 copies rather than rebuilds. Naming the fields to carry over makes the
# patch an allowlist that silently drops whatever Istio emits next; that already
# cost once, when failure_mode_allow was hardcoded here and made the patched
# route fail open where the original failed closed.
#
# Pool cluster names carry a hash Istio derives from the InferencePool, so the
# pool-cluster to picker-cluster mapping is rebuilt from live names every run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRINT_ONLY=""
[[ "${1:-}" == "--print" ]] && PRINT_ONLY=1

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
docker_socket_guard

mkdir -p "$RESULTS"
DUMP="$RESULTS/prefix-routes.json"
capture "config_dump?resource=dynamic_route_configs" "$DUMP" \
    || err "empty route config capture from the gateway admin API"

POOLS="$RESULTS/inferencepool-services.json"
kubectl get svc -A -l internal.istio.io/service-semantics=inferencepool -o json \
    > "$POOLS" 2>/dev/null || err "could not list InferencePool services"

OUT_YAML="$RESULTS/envoyfilter-per-pool-extproc.yaml"
OUT_DIFF="$RESULTS/envoyfilter-per-pool-extproc-diff.json"

python3 - "$DUMP" "$POOLS" "$NS" "$GATEWAY_NAME" "$OUT_YAML" "$OUT_DIFF" <<'PYEOF'
import json
import sys

dump_path, pools_path, ns, gw_name, out_yaml, out_diff = sys.argv[1:7]

EXT_PROC = "envoy.filters.http.ext_proc"
PER_ROUTE_TYPE = ("type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3."
                  "ExtProcPerRoute")
LBL = "istio.io/inferencepool-"


def key(d, *names):
    """Istio's dynamic config dump is camelCase; a static one is snake_case."""
    for name in names:
        if isinstance(d, dict) and name in d:
            return d[name]
    return None


# Pool cluster -> that pool's own picker cluster, from the labels Istio puts on
# the Service it synthesises per InferencePool. Reading the labels rather than
# parsing names means any InferencePool works, whoever created it.
pickers = {}
for svc in json.load(open(pools_path)).get("items", []):
    meta = svc["metadata"]
    labels = meta.get("labels", {})
    picker_svc = labels.get(LBL + "extension-service")
    picker_port = labels.get(LBL + "extension-port")
    if not picker_svc or not picker_port:
        continue
    namespace = meta["namespace"]
    for port in svc["spec"].get("ports", []):
        pool_cluster = "outbound|%s||%s.%s.svc.cluster.local" % (
            port["port"], meta["name"], namespace)
        pickers[pool_cluster] = "outbound|%s||%s.%s.svc.cluster.local" % (
            picker_port, picker_svc, namespace)
if not pickers:
    sys.exit("no InferencePool services found; is the inference extension enabled?")


def route_override(route):
    tpfc = key(route, "typed_per_filter_config", "typedPerFilterConfig") or {}
    return key(tpfc.get(EXT_PROC) or {}, "overrides")


def weighted_of(route):
    return key(key(route, "route") or {},
               "weighted_clusters", "weightedClusters") or {}


# Every route that splits across two or more InferencePools under a single
# route-level override. That is the defect's shape, and finding it by shape
# rather than by name is what makes this work against a route somebody else's
# controller wrote.
targets = []
for config in json.load(open(dump_path)).get("configs", []):
    for vhost in config.get("route_config", {}).get("virtual_hosts", []):
        for route in vhost.get("routes", []):
            clusters = weighted_of(route).get("clusters", [])
            pooled = [c for c in clusters if c["name"] in pickers]
            if len(pooled) >= 2 and route_override(route):
                targets.append((vhost["name"], route))

# One patch per (vhost, route name). Istio matches a route by exact string
# equality on its name, so a table carrying the same rule name more than once -
# which KServe's controller emits - cannot have those occurrences targeted
# separately. Emitting a patch each would just repeat the same match. This is a
# limit of the workaround, not something to paper over: where a name repeats,
# whichever occurrences Istio's matcher hits are the ones that get fixed.
seen = set()
unique = []
for vhost_name, route in targets:
    ident = (vhost_name, route["name"])
    if ident in seen:
        continue
    seen.add(ident)
    unique.append((vhost_name, route))
duplicated = len(targets) - len(unique)
targets = unique
if not targets:
    sys.exit("no route splits across two or more InferencePools with a route-level "
             "ext_proc override; the defect this patches is not present")


def override_naming(source, picker):
    """Istio's own override verbatim, with only the picker cluster swapped."""
    copy = json.loads(json.dumps(source))
    grpc = key(copy, "grpc_service", "grpcService")
    if grpc is None:
        grpc = copy["grpc_service"] = {}
    envoy_grpc = key(grpc, "envoy_grpc", "envoyGrpc")
    if envoy_grpc is None:
        envoy_grpc = grpc["envoy_grpc"] = {}
    envoy_grpc.pop("clusterName", None)
    envoy_grpc["cluster_name"] = picker
    return copy


patches = []
report = []
for vhost_name, original in targets:
    orig_name = original["name"]
    fixed_name = orig_name + ".fixed"
    source = route_override(original)

    fixed = json.loads(json.dumps(original))
    fixed["name"] = fixed_name
    edits = [{"edit": "rename", "from": orig_name, "to": fixed_name}]

    for spelling in ("typed_per_filter_config", "typedPerFilterConfig"):
        if spelling in fixed and EXT_PROC in fixed[spelling]:
            del fixed[spelling][EXT_PROC]
            if not fixed[spelling]:
                del fixed[spelling]
            edits.append({"edit": "drop-route-level-ext_proc"})
            break

    for cluster in weighted_of(fixed).get("clusters", []):
        picker = pickers.get(cluster["name"])
        if picker is None:
            # Not an InferencePool - an ordinary Service sharing the rule. It has
            # no picker of its own, and "no picker" is what `disabled` means.
            cluster["typed_per_filter_config"] = {
                EXT_PROC: {"@type": PER_ROUTE_TYPE, "disabled": True}}
            edits.append({"edit": "disable-weighted-cluster-ext_proc",
                          "cluster": cluster["name"]})
            continue
        cluster["typed_per_filter_config"] = {
            EXT_PROC: {"@type": PER_ROUTE_TYPE,
                       "overrides": override_naming(source, picker)}}
        edits.append({"edit": "add-weighted-cluster-ext_proc",
                      "cluster": cluster["name"], "picker": picker})

    patches.append({
        "applyTo": "HTTP_ROUTE",
        "match": {"context": "GATEWAY",
                  "routeConfiguration": {
                      "vhost": {"name": vhost_name, "route": {"name": orig_name}}}},
        "patch": {"operation": "INSERT_BEFORE", "value": fixed},
    })
    report.append({"route": orig_name, "vhost": vhost_name,
                   "source_overrides": source, "edits": edits})

envoy_filter = {
    "apiVersion": "networking.istio.io/v1alpha3",
    "kind": "EnvoyFilter",
    "metadata": {"name": "per-pool-extproc", "namespace": ns},
    "spec": {
        "workloadSelector": {
            "labels": {"gateway.networking.k8s.io/gateway-name": gw_name}},
        "configPatches": patches,
    },
}

with open(out_yaml, "w") as handle:
    json.dump(envoy_filter, handle, indent=2)   # JSON is valid YAML
    handle.write("\n")
with open(out_diff, "w") as handle:
    json.dump({"routes": report,
               # Kept flat as well: the fix scenario asserts against one route.
               "route": report[0]["route"],
               "source_overrides": report[0]["source_overrides"],
               "edits": report[0]["edits"]}, handle, indent=2)
    handle.write("\n")
print("wrote %s (%d patch(es), %d pools mapped%s)"
      % (out_yaml, len(patches), len(pickers),
         ", %d duplicate route name(s) collapsed" % duplicated if duplicated else ""))

PYEOF

if [[ -n "$PRINT_ONLY" ]]; then
    cat "$OUT_YAML"
else
    ok "EnvoyFilter rendered: $OUT_YAML"
    ok "route diff:           $OUT_DIFF"
fi
