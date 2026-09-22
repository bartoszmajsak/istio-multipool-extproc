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
echo "Routes on this gateway, in the order Envoy evaluates them:"
jq -r '
  def epp: (."envoy.filters.http.ext_proc" // null)
    | if . == null then "NONE"
      elif .overrides.grpc_service.envoy_grpc.cluster_name then (.overrides.grpc_service.envoy_grpc.cluster_name | split("||")[1] // .)
      elif .disabled then "DISABLED" else "present" end;
  def short: if . == null then "-" else (split("||")[1] // .) end;
  [ .configs[] | select(."@type" | test("RoutesConfigDump"))
    | (.dynamic_route_configs[]?.route_config, .static_route_configs[]?.route_config)
    | .virtual_hosts[]? as $vh | $vh.routes[]?
    | . as $r
    | { vhost: $vh.name,
        name: $r.name,
        path: (($r.match.path // $r.match.prefix // $r.match.path_separated_prefix // ($r.match.safe_regex.regex // null) // "?") | tostring),
        backends: ([$r.route.cluster] + [$r.route.weighted_clusters.clusters[]?.name] | map(select(.) | short)),
        pooled: ([$r.route.cluster] + [$r.route.weighted_clusters.clusters[]?.name] | map(select(. and test("-ip-"))) | length > 0),
        epp: (($r.typed_per_filter_config // {}) | epp),
        per_cluster: [$r.route.weighted_clusters.clusters[]? | (.typed_per_filter_config // {}) | epp] } ]
  | to_entries
  | map(.value + {idx: .key})
  # a route is unreachable if an earlier route already claims its path
  | . as $all
  | map(. as $e | $e + {shadowed: (([$all[] | select(.vhost == $e.vhost and .path == $e.path)] | .[0].idx) < $e.idx)})
  | .[]
  | "  [\(.idx)] \(.path)"
    + (if (.name // "") != "" then "  \(.name)" else "" end)
    + "  backend=\(.backends | join(","))"
    + "  epp=\(.epp)"
    + (if (.per_cluster | length) > 0 then "  per-cluster=\(.per_cluster | join(","))" else "" end)
    + (if .pooled then "" else "  <- no InferencePool, EPP not involved by design" end)
    + (if .shadowed then "  <- SHADOWED by an earlier route on this path" else "" end)' "$DUMP"

echo ""
echo "Detection:"
jq -r '
  def epp: (."envoy.filters.http.ext_proc" // null)
    | if . == null then "NONE"
      elif .overrides.grpc_service.envoy_grpc.cluster_name then .overrides.grpc_service.envoy_grpc.cluster_name
      elif .disabled then "DISABLED" else "present" end;
  [ .configs[] | select(."@type" | test("RoutesConfigDump"))
    | (.dynamic_route_configs[]?.route_config, .static_route_configs[]?.route_config)
    | .virtual_hosts[]? as $vh | $vh.routes[]?
    | . as $r
    | { vhost: $vh.name,
        name: $r.name,
        path: (($r.match.path // $r.match.prefix // $r.match.path_separated_prefix // ($r.match.safe_regex.regex // null) // "?") | tostring),
        pools: ([$r.route.cluster] + [$r.route.weighted_clusters.clusters[]?.name] | map(select(. and test("-ip-")))),
        svc_backends: ([$r.route.cluster] + [$r.route.weighted_clusters.clusters[]?.name] | map(select(. and (test("-ip-") | not)))),
        route_epp: (($r.typed_per_filter_config // {}) | epp),
        cluster_epp: [$r.route.weighted_clusters.clusters[]? | (.typed_per_filter_config // {}) | epp] } ]
  # Envoy serves the first route matching a path; later duplicates never run.
  | (group_by(.vhost + "\u0000" + .path) | map(.[0])) as $live
  | ($live | map(select(.pools | length > 0))) as $pooled
  | ($live | map(select((.pools | length) == 0 and (.svc_backends | length) > 0))) as $bypass
  | ($pooled | map(select(.route_epp == "NONE" and ((.cluster_epp | map(select(. != "NONE")) | length) == 0)))) as $missing
  | ($pooled | map(select((.pools | length) > 1 and .route_epp != "NONE"
                          and ((.cluster_epp | map(select(. != "NONE")) | length) == 0)))) as $multipool
  | ($pooled | map(select(.route_epp != "NONE")) | group_by(.name)
     | map(select(length > 1 and ([.[].route_epp] | unique | length) == 1
                  and ([.[].pools[0]] | unique | length) > 1)) | flatten) as $collide
  | (if ($missing|length) > 0 then
       "  PROBLEM: \($missing|length) pool-backed route(s) have NO endpoint picker",
       ($missing[] | "    - [\(.path)] \(.name)") else empty end),
    (if ($multipool|length) > 0 then
       "  PROBLEM: \($multipool|length) route(s) span several pools under a single route-level picker",
       ($multipool[] | "    - [\(.path)] \(.name)  picker=\(.route_epp | split("||")[1] // .)") else empty end),
    (if ($collide|length) > 0 then
       "  PROBLEM: \($collide|length) route(s) share a rule name and carry the same picker for different pools",
       ($collide[] | "    - [\(.path)] \(.name)  pool=\(.pools[0] | split("||")[1] // .)  picker=\(.route_epp | split("||")[1] // .)") else empty end),
    (if (($missing|length)+($multipool|length)+($collide|length)) == 0 then
       "  OK: all \($pooled|length) pool-backed route(s) have a picker matching their own pool" else empty end),
    (if ($bypass|length) > 0 then
       "",
       "  NOTE: \($bypass|length) reachable route(s) have no InferencePool backend. Traffic matching",
       "  these never reaches an endpoint picker - that is correct for them, but if requests are",
       "  arriving here instead of on a pool-backed route, the EPP will look bypassed:",
       ($bypass[] | "    - [\(.path)] \(.name) -> \(.svc_backends | join(","))") else empty end),
    "",
    "  EPP mappings (a picker against more than one pool is the fault):",
    ($pooled | map(select(.route_epp != "NONE")) | group_by(.route_epp)[]
     | "    - \(.[0].route_epp | split("||")[1] // .)",
       ("      -> " + ([.[].pools[] | split("||")[1] // .] | unique | join("\n      -> "))))' "$DUMP"
rm -f "$DUMP"
