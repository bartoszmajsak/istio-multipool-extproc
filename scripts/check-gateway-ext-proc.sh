#!/usr/bin/env bash
# Reports how endpoint pickers are wired on a gateway, and whether any route
# lost or swapped one. Reads only what the cluster already has - no traffic.
#
#   ./scripts/check-gateway-ext-proc.sh <gateway-name> [namespace]
set -uo pipefail

GW="${1:?usage: $0 <gateway-name> [namespace]}"
NS="${2:-}"

kc() { kubectl "$@"; }

if [[ -z "$NS" ]]; then
    NS=$(kc get gateway -A -o jsonpath="{range .items[?(@.metadata.name=='${GW}')]}{.metadata.namespace}{'\n'}{end}" 2>/dev/null | head -1)
fi
[[ -n "$NS" ]] || { echo "gateway '$GW' not found in any namespace"; exit 1; }

POD=$(kc -n "$NS" get pods -l "gateway.networking.k8s.io/gateway-name=${GW}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$POD" ]] || { echo "no Envoy pod for gateway ${NS}/${GW}"; exit 1; }

echo "Gateway: ${NS}/${GW}"
echo "Envoy pod: ${POD}"
echo ""
echo "Gateway status:"
kc -n "$NS" get gateway "$GW" -o json 2>/dev/null \
  | jq -r '.status.conditions[]? | "  \(.type)=\(.status) (\(.reason))"'

echo ""
echo "EnvoyFilters affecting this Gateway:"
kc get envoyfilter -A -o json 2>/dev/null | jq -r --arg gw "$GW" '
  .items[]
  | . as $ef
  | ($ef.spec.workloadSelector.labels["gateway.networking.k8s.io/gateway-name"] // "") as $sel
  | select($sel == $gw or $sel == "")
  | "  \($ef.metadata.namespace)/\($ef.metadata.name) [\(if $sel == "" then "broad/no selector" else "gateway=" + $sel end)]",
    ( $ef.spec.configPatches[]?
      | "    - \(.applyTo) \(.patch.operation)"
        + (if (.match.routeConfiguration.vhost.route.name // "") != "" then " route=\(.match.routeConfiguration.vhost.route.name)" else "" end)
        + (if (tostring | test("ext_proc")) then " ext_proc-related" else "" end) )'

echo ""
echo "Fetching live Envoy config dump..."
DUMP=$(mktemp)
kc -n "$NS" exec "$POD" -c istio-proxy -- pilot-agent request GET config_dump > "$DUMP" 2>/dev/null \
  || kc -n "$NS" exec "$POD" -c istio-proxy -- curl -s localhost:15000/config_dump > "$DUMP" 2>/dev/null
[[ -s "$DUMP" ]] || { echo "  could not read config dump"; exit 1; }

echo ""
echo "HTTP filter chains:"
jq -r '
  .configs[] | select(."@type" | test("ListenersConfigDump"))
  | .dynamic_listeners[]?.active_state.listener
  | .filter_chains[]?.filters[]?
  | select(.name == "envoy.filters.network.http_connection_manager")
  | [.typed_config.http_filters[]?.name] | "  - " + join(" -> ")' "$DUMP" | sort -u

echo ""
echo "EPP-related CDS clusters:"
jq -r '.configs[] | select(."@type" | test("ClustersConfigDump"))
  | (.dynamic_active_clusters[]?, .static_clusters[]?) | .cluster.name
  | select(test("\\|9002\\|\\|") or test("epp|endpoint-picker"))
  | "  - " + .' "$DUMP" | sort -u

echo ""
echo "Inference routes:"
jq -r '
  def epp: (."envoy.filters.http.ext_proc" // null)
    | if . == null then "NONE"
      elif .overrides.grpc_service.envoy_grpc.cluster_name then .overrides.grpc_service.envoy_grpc.cluster_name
      elif .disabled then "DISABLED" else "present" end;
  .configs[] | select(."@type" | test("RoutesConfigDump"))
  | (.dynamic_route_configs[]?.route_config, .static_route_configs[]?.route_config)
  | .virtual_hosts[]? | .routes[]?
  | . as $r
  | ([$r.route.cluster] + [$r.route.weighted_clusters.clusters[]?.name] | map(select(.)) ) as $backends
  | select($backends | any(test("-ip-|inference|pool")))
  | "  - \($r.name) | backend=\($backends | join(",")) | EPP=\(($r.typed_per_filter_config // {}) | epp)"
      + (if ($r.route.weighted_clusters.clusters // []) | length > 0
         then " | per-cluster=" + ([$r.route.weighted_clusters.clusters[] | (.typed_per_filter_config // {}) | epp] | join(","))
         else "" end)' "$DUMP" | sort

echo ""
echo "Detection:"
jq -r '
  def epp: (."envoy.filters.http.ext_proc" // null)
    | if . == null then "NONE"
      elif .overrides.grpc_service.envoy_grpc.cluster_name then .overrides.grpc_service.envoy_grpc.cluster_name
      elif .disabled then "DISABLED" else "present" end;
  [ .configs[] | select(."@type" | test("RoutesConfigDump"))
    | (.dynamic_route_configs[]?.route_config, .static_route_configs[]?.route_config)
    | .virtual_hosts[]? | .routes[]?
    | . as $r
    | ([$r.route.cluster] + [$r.route.weighted_clusters.clusters[]?.name] | map(select(. and test("-ip-")))) as $pools
    | select($pools | length > 0)
    | { name: $r.name,
        path: (($r.match.path // $r.match.prefix // $r.match.path_separated_prefix // $r.match.safe_regex.regex // "?") | tostring),
        pools: $pools,
        route_epp: (($r.typed_per_filter_config // {}) | epp),
        cluster_epp: [$r.route.weighted_clusters.clusters[]? | (.typed_per_filter_config // {}) | epp] } ]
  # Envoy takes the first route whose match wins, so a later route on the same path
  # is unreachable. Judging the table means judging only what actually serves.
  | (group_by(.path) | map(.[0])) as $routes
  | ($routes | length) as $total
  | ($routes | map(select(.route_epp == "NONE" and (.cluster_epp | map(select(. != "NONE")) | length) == 0))) as $missing
  | ($routes | map(select((.pools | length) > 1 and .route_epp != "NONE"
                          and ((.cluster_epp | map(select(. != "NONE")) | length) == 0)))) as $multipool
  | ($routes | map(select(.route_epp != "NONE")) | group_by(.name)
     | map(select(length > 1 and ([.[].route_epp] | unique | length) == 1
                  and ([.[].pools[0]] | unique | length) > 1)) | flatten) as $collide
  | (if ($missing | length) > 0 then
        "  PROBLEM: \($missing|length) of \($total) InferencePool-backed route(s) have NO endpoint picker",
        ($missing[] | "    - \(.name)  pools=\(.pools|join(","))")
     else empty end),
    (if ($multipool | length) > 0 then
        "  PROBLEM: \($multipool|length) route(s) span several pools under a single route-level picker",
        ($multipool[] | "    - \(.name)  pools=\(.pools|join(","))  picker=\(.route_epp)")
     else empty end),
    (if ($collide | length) > 0 then
        "  PROBLEM: \($collide|length) route(s) share a rule name and carry the same picker for different pools",
        ($collide[] | "    - \(.name)  pool=\(.pools[0])  picker=\(.route_epp)")
     else empty end),
    (if (($missing|length) + ($multipool|length) + ($collide|length)) == 0 then
        "  OK: all \($total) InferencePool-backed route(s) have a picker matching their own pool"
     else empty end),
    "  EPP mappings:",
    ($routes | map(select(.route_epp != "NONE")) | group_by(.route_epp)[]
     | "    - \(.[0].route_epp)", ("      -> " + ([.[].pools[]] | unique | join("\n      -> "))))' "$DUMP"
rm -f "$DUMP"
