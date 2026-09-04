#!/usr/bin/env bash
# Istio multi-pool ext_proc spike - validation.
#
# Usage:
#   ./validate.sh                                 # the reproduction, ~25s
#   ./validate.sh --all                           # every scenario
#   ./validate.sh --scenario bypass
#   ./validate.sh --scenario outage --requests 200
#
# Scenarios:
#   bypass        one rule, two pools: which picker is consulted, and for whose
#                 traffic
#   outage        the winning picker refuses; how far the damage reaches
#   fix           an EnvoyFilter supplying per-weighted-cluster ext_proc, and the
#                 outage re-run underneath it
#
# Every scenario sets both pickers' modes explicitly and reads them back before
# sending anything, so a single scenario can be run on its own and no
# scenario inherits the previous one's state. Raw evidence is written to
# results/ before any of it
# is scored, so a failed scenario can be read by hand afterwards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The default is all three scenarios, because the three together are the
# argument: it is broken, here is what that costs, and here is the same thing
# with per-backend config. Any one of them alone invites the obvious objection.
SCENARIO="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario)      SCENARIO="${2:?--scenario needs a value}"; shift 2 ;;
        --verbose|-v)    VERBOSE=1; shift ;;
        --all)           SCENARIO="all"; shift ;;
        --requests) REQUESTS="${2:?--requests needs a value}"; shift 2 ;;
        -h|--help)  sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
    esac
done
export REQUESTS

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
docker_socket_guard

SCENARIOS_ALL="bypass outage fix"
mkdir -p "$RESULTS"
rm -f "$RESULTS"/[0-9]-*.headline

GW_POD="$(gateway_pod)"
[[ -n "$GW_POD" ]] || err "no gateway pod in namespace $NS - run ./setup.sh first"
# Refuses to score a run whose data plane does not match the version it would be
# stamped with. Every claim in results/ names an (istio, envoy) pair, and a pair
# that was never actually in place is worse than no result at all.
GW_IMAGE="$(gateway_pod_image || true)"
[[ "$GW_IMAGE" == *":${ISTIO_VERSION}" ]] \
    || err "the serving gateway pod runs '${GW_IMAGE:-unknown}' but ISTIO_VERSION is ${ISTIO_VERSION}; re-run ./setup.sh"
CLIENT_POD="$(client_pod)"
[[ -n "$CLIENT_POD" ]] || err "no client pod in namespace $NS - run ./setup.sh first"
GW_SVC=$(kubectl get svc -n "$NS" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}')
GW_URL="http://${GW_SVC}.${NS}.svc.cluster.local"

ENVOY_VERSION=$(envoy_admin server_info \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","unknown"))' \
    2>/dev/null || echo unknown)
# The full build string (sha/flavour/TLS) is recorded in versions.txt; on screen
# the version is what a reader needs.
STAMP="istio=${ISTIO_VERSION} envoy=$(echo "$ENVOY_VERSION" | cut -d/ -f2)"

echo -e "${BOLD}Istio multi-pool ext_proc validation${NC}"
echo "$STAMP"
echo "Split:     pool-a=${WEIGHT_A} pool-b=${WEIGHT_B}   requests per target: ${REQUESTS}"
echo "Gateway:   $GW_URL   (host ${HOSTNAME_})"
echo "Results:   $RESULTS"

# A picker's replica count is load-bearing: a mode flip is one HTTP call to one
# pod, so with two replicas half the traffic would keep the old mode and a total
# outage would be reported as a partial one.
for epp in epp-a epp-b; do
    replicas=$(kubectl get deploy -n "$NS" "$epp" -o jsonpath='{.status.readyReplicas}')
    [[ "$replicas" == "1" ]] || err "$epp has $replicas ready replicas; the mode flip assumes exactly 1"
done

# Preflight: start from a route table nobody has patched.
#
# The fix scenarios remove their EnvoyFilters when they finish, but an
# interrupted run does not finish, and a leftover filter would silently move
# every later scenario onto a patched route. The bypass scenario is sensitive to
# that and would fail rather than lie, but a harness that depends on the previous
# run having exited cleanly is a harness that reports the wrong thing the first
# time somebody presses Ctrl-C.
#
# So this deletes what the spike owns, and then asserts the table is actually
# clean - a patched route still present after the delete means something outside
# this spike put it there, and continuing would be scoring someone else's config.
true
_stale=$(kubectl get envoyfilter -n "$NS" -o name 2>/dev/null | wc -l)
if [[ "$_stale" -gt 0 ]]; then
    warn "$_stale EnvoyFilter(s) left over; removing them"
    kubectl delete envoyfilter -n "$NS" --all >/dev/null 2>&1 || true
fi
for _route in "$FIXED_ROUTE_NAME"; do
    wait_for_route_gone "$_route" 60 \
        || err "route $_route is still in the gateway's route table after deleting every EnvoyFilter in $NS; something outside this spike is patching it and no scenario below would mean what it says"
done

# Both pools start full. A scenario that drained one and then died would leave
# the next run measuring an outage it did not cause.
for _pool in pool-a pool-b; do
    _n="$(pool_endpoints "$_pool")"
    if [[ "$_n" != "$BACKEND_REPLICAS" ]]; then
        warn "$_pool has $_n endpoints, expected $BACKEND_REPLICAS; refilling"
        fill_pool "$_pool"
    fi
done
true


SCENARIOS_RUN=""
TOTAL_FAILURES=0

# Request ids carry a per-run stamp. The gateway's access log is a rolling
# buffer that outlives a run, so a re-run of the same scenario would otherwise match
# the previous run's records as well as its own - and a stale run agreeing with
# the current one is indistinguishable from twice the evidence.
RUN_ID="$(date +%s)"


# One exec drives the whole burst and every target runs in its own thread, so
# the bursts overlap in time. That overlap is the claim in the outage scenarios: the
# weighted rule dies *while* the healthy pool's own route keeps serving, which
# two consecutive bursts could not distinguish from a pool that recovered in
# between.
run_burst() {
    local tag="$1" out="$2"; shift 2
    local spec=""
    for t in "$@"; do spec="${spec}${t};"; done
    # --quiet --no-summary --log-format=raw so stdout is nothing but the
    # per-request records the script prints.
    kubectl exec -n "$NS" "$CLIENT_POD" -- k6 run --quiet --no-color \
        --log-format=raw --summary-mode=compact \
        -e "BASE=$GW_URL" -e "HOST=$HOSTNAME_" -e "N=$REQUESTS" \
        -e "TAG=${tag}.${RUN_ID}" -e "TARGETS=$spec" \
        -e "POOL_A_IPS=$(pool_pod_ips backend-a)" \
        -e "POOL_B_IPS=$(pool_pod_ips backend-b)" \
        /scripts/burst.js 2>&1 | tee "$RESULTS/${tag}-k6.txt" \
        | grep -E "^[0-9]{10,} " > "$out" || true
    # k6's own check result, in k6's own words. It states the finding more
    # plainly than any assertion of ours: the share of requests whose endpoint
    # was chosen by the picker belonging to the pool that actually served them.
    [[ -n "${VERBOSE:-}" ]] && grep -E "endpoint chosen by the pool that served it|↳" \
        "$RESULTS/${tag}-k6.txt" 2>/dev/null | sed 's/^ */  /'
    true
}

# Envoy's access log reaches `kubectl logs` a beat after the response reaches the
# client, so a single capture taken the moment a burst returns silently holds a
# subset. Scoring that subset would understate every count in the scenario, so the
# capture waits for the records it knows are coming - and score.py asserts the
# total independently, since a lagging log and a genuinely missing record look
# the same in a file.
pool_pod_ips() {
    kubectl get pods -n "$NS" -l "app=${1:?app required}" \
        -o jsonpath='{range .items[*]}{.status.podIP}{","}{end}' 2>/dev/null
}

# Runs the probe in the background at a steady rate while the scenario changes
# the cluster underneath it. Discrete bursts sample either side of an outage and
# can only say that requests failed; a probe that never stops says when it
# started, when it ended and how long it lasted.
start_probe() {
    local tag="$1" out="$2" duration="$3"; shift 3
    local spec=""
    for t in "$@"; do spec="${spec}${t};"; done
    kubectl exec -n "$NS" "$CLIENT_POD" -- k6 run --quiet --no-color \
        --log-format=raw --summary-mode=compact \
        -e "BASE=$GW_URL" -e "HOST=$HOSTNAME_" -e "DURATION=$duration" \
        -e "RATE=${PROBE_RATE:-20}" -e "TAG=${tag}.${RUN_ID}" -e "TARGETS=$spec" \
        -e "POOL_A_IPS=$(pool_pod_ips backend-a)" \
        -e "POOL_B_IPS=$(pool_pod_ips backend-b)" \
        /scripts/burst.js > "$RESULTS/${tag}-k6.txt" 2>&1 &
    PROBE_PID=$!
}

# Timestamps a phase boundary in the same clock the probe records, so the report
# can say how long after the trigger the first failure landed.
mark() {
    printf '%s\t%s\n' "$(date +%s%3N)" "$1" >> "$RESULTS/${MARK_TAG}-marks.tsv"
}

capture_access() {
    local tag="$1" out="$2" want="${3:-0}" deadline
    deadline=$(( $(date +%s) + 30 ))
    while :; do
        # The pod is resolved on every attempt rather than once per run: a
        # gateway that rolled mid-run would otherwise leave every later capture
        # empty, which scores as "no traffic reached Envoy".
        kubectl logs -n "$NS" "$(gateway_pod)" -c istio-proxy --tail=20000 2>/dev/null \
            | grep "\"${tag}.${RUN_ID}-" > "$out" || true
        [[ "$want" -le 0 ]] && break
        (( $(wc -l < "$out") >= want )) && break
        (( $(date +%s) >= deadline )) && break
        sleep 1
    done
}

# Envoy rejects an invalid route config by keeping the previous one, silently
# from the outside. An EnvoyFilter has no status either, so without this a
# rejected patch and a patch that does not help look identical.
rds_rejected() {
    envoy_admin "stats?filter=rds.*update_rejected" \
        | awk -F': ' '{ total += $2 } END { print total + 0 }'
}

snapshot_status() {
    local out="$1"
    python3 - "$out" <<'PYEOF' 2>/dev/null || echo "[]" > "$out"
import json, subprocess, sys

out = sys.argv[1]
rows = []


def get(kind, name, path):
    return subprocess.run(["kubectl", "get", kind, name, "-n",
                           __import__("os").environ["NS"], "-o", "jsonpath=" + path],
                          capture_output=True, text=True).stdout.strip()


ns_kinds = [
    ("gateway", __import__("os").environ["GATEWAY_NAME"], "Programmed",
     '{.status.conditions[?(@.type=="Programmed")].status}'),
    ("httproute", "split", "Accepted",
     '{.status.parents[0].conditions[?(@.type=="Accepted")].status}'),
    ("httproute", "split", "ResolvedRefs",
     '{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}'),
    ("inferencepool", "pool-a", "Accepted",
     '{.status.parents[0].conditions[?(@.type=="Accepted")].status}'),
    ("inferencepool", "pool-b", "Accepted",
     '{.status.parents[0].conditions[?(@.type=="Accepted")].status}'),
]
for kind, name, condition, path in ns_kinds:
    rows.append([kind, name, condition, get(kind, name, path)])
json.dump(rows, open(out, "w"), indent=2)
PYEOF
}
export NS GATEWAY_NAME

score() {
    local tag="$1" rc=0
    # Re-read every time. Draining and refilling a pool replaces its pods, so a
    # map captured at startup would leave every later scenario unable to say
    # which pool an endpoint belongs to - which shows up as a picker attributed
    # as "?" rather than as an error.
    local POOL_IPS_A POOL_IPS_B
    POOL_IPS_A=$(kubectl get pods -n "$NS" -l app=backend-a \
        -o jsonpath='{range .items[*]}{.status.podIP}{","}{end}')
    POOL_IPS_B=$(kubectl get pods -n "$NS" -l app=backend-b \
        -o jsonpath='{range .items[*]}{.status.podIP}{","}{end}')
    PYTHONUNBUFFERED=1 python3 "$SCRIPT_DIR/score.py" --scenario "$tag" --results "$RESULTS" \
        --requests "$REQUESTS" --weight-a "$WEIGHT_A" --weight-b "$WEIGHT_B" \
        --namespace "$NS" --split-route "$SPLIT_ROUTE_NAME" \
        --fixed-route "$FIXED_ROUTE_NAME" \
        --pool-ips "a=${POOL_IPS_A}" --pool-ips "b=${POOL_IPS_B}" \
        --stamp "$STAMP" ${VERBOSE:+--verbose} || rc=$?
    TOTAL_FAILURES=$((TOTAL_FAILURES + rc))
}

# --------------------------------------------------------------------------

scenario_bypass() {
    header "Scenario: bypass - one rule, two pools, one picker"
    step "1/3  both pools healthy, ${WEIGHT_A}:${WEIGHT_B} across two InferencePools"
    substep "sending ${REQUESTS} requests to the weighted rule, and ${REQUESTS} to pool-a's own route"
    capture "config_dump?resource=dynamic_route_configs" "$RESULTS/bypass-routes.json" \
        || err "empty route capture"
    run_burst bypass "$RESULTS/bypass-traffic.log" \
        "split=${SPLIT_PATH}${MODEL_PATH}" "a-only=/a-only${MODEL_PATH}"
    capture_access bypass "$RESULTS/bypass-access.log" $((REQUESTS * 2))
    score bypass
}


scenario_outage() {
    header "Scenario: outage - the winning picker has no endpoints"
    MARK_TAG=outage
    : > "$RESULTS/outage-marks.tsv"
    capture "config_dump?resource=dynamic_route_configs" "$RESULTS/outage-routes.json" \
        || err "empty route capture"

    # The probe runs across the whole thing: healthy, drained, refilled. What it
    # measures is the shape of the window, not just that requests failed inside
    # it.
    step "2/3  scaling pool-b (the ${WEIGHT_B}0% canary) to zero, as during a rollout"
    substep "probing continuously for ${PROBE_DURATION:-70s} across the drain and the refill"
    start_probe outage "$RESULTS/outage-traffic.log" "${PROBE_DURATION:-70s}" \
        "split=${SPLIT_PATH}${MODEL_PATH}" "a-only=/a-only${MODEL_PATH}"
    sleep 6
    mark healthy

    mark drain-start
    drain_pool pool-b
    mark drained
    substep "pool-b has no endpoints"
    # The status snapshot has to be taken while the gateway is actually down.
    snapshot_status "$RESULTS/outage-status.json"
    sleep 8

    mark refill-start
    substep "scaling pool-b back up"
    fill_pool pool-b
    mark refilled
    substep "pool-b serving again; waiting for the probe to finish"

    wait "$PROBE_PID" || true
    grep -E "^[0-9]{10,} " "$RESULTS/outage-k6.txt" > "$RESULTS/outage-traffic.log" || true
    [[ -n "${VERBOSE:-}" ]] && grep -E "endpoint chosen by the pool that served it|↳" \
        "$RESULTS/outage-k6.txt" 2>/dev/null | sed 's/^ */  /'
    true
    # Every probed request should reach the access log, so the traffic log's own
    # line count is what to wait for. Passing 0 here skipped the wait entirely
    # and captured an empty file.
    capture_access outage "$RESULTS/outage-access.log" \
        "$(wc -l < "$RESULTS/outage-traffic.log")"
    score outage
}


scenario_fix() {
    header "Scenario: fix - per-weighted-cluster ext_proc via EnvoyFilter"

    step "3/3  same outage, with an EnvoyFilter giving each pool its own picker"
    substep "rendering the filter from the route Envoy is running"
    local rejected_before rejected_after
    rejected_before=$(rds_rejected)
    "$SCRIPT_DIR/render-envoyfilter.sh" >/dev/null \
        || err "could not render the EnvoyFilter"
    kubectl apply -f "$RESULTS/envoyfilter-per-pool-extproc.yaml" >/dev/null 2>&1 \
        || err "EnvoyFilter rejected by the API server"
    wait_for_route "$FIXED_ROUTE_NAME" 60 \
        || err "the patched route never reached the gateway; the filter applied but did nothing"
    substep "patched route loaded; sending ${REQUESTS} requests"
    rejected_after=$(rds_rejected)
    printf '{"rejected_before": %s, "rejected_after": %s, "rejected_delta": %s}\n' \
        "$rejected_before" "$rejected_after" "$((rejected_after - rejected_before))" \
        > "$RESULTS/fix-stats.json"

    capture "config_dump?resource=dynamic_route_configs" "$RESULTS/fix-routes.json" \
        || err "empty route capture"
    run_burst fix "$RESULTS/fix-traffic.log" "split=${SPLIT_PATH}${MODEL_PATH}"
    capture_access fix "$RESULTS/fix-access.log" $((REQUESTS * 1))
    score fix

    header "Scenario: fix - the outage re-run underneath the patch"
    substep "draining pool-b again, this time under the patch"
    drain_pool pool-b
    run_burst fix-outage "$RESULTS/fix-outage-traffic.log" "split=${SPLIT_PATH}${MODEL_PATH}"
    capture_access fix-outage "$RESULTS/fix-outage-access.log" $((REQUESTS * 1))
    score fix-outage

    fill_pool pool-b
    kubectl delete -f "$RESULTS/envoyfilter-per-pool-extproc.yaml" >/dev/null 2>&1 || true
    wait_for_route_gone "$FIXED_ROUTE_NAME" 60 \
        || warn "the patched route is still in the route table; later scenarios may be affected"
}



for scenario in $SCENARIOS_ALL; do
    if [[ "$SCENARIO" == "all" || "$SCENARIO" == "$scenario" ]]; then
        case "$scenario" in
            bypass)       scenario_bypass ;;
            ordering)     scenario_ordering ;;
            outage)       scenario_outage ;;
            control)      scenario_control ;;
            fix)          scenario_fix ;;
        esac
        SCENARIOS_RUN="$SCENARIOS_RUN $scenario"
    fi
done

if [[ -z "${SCENARIOS_RUN// /}" ]]; then
    err "No scenarios matched --scenario '$SCENARIO'. One of: all $SCENARIOS_ALL"
fi

echo ""
for h in "$RESULTS"/[0-9]-*.headline; do
    [[ -f "$h" ]] || continue
    printf "  %s. %s\n" "$(basename "$h" | cut -c1)" "$(cat "$h")"
done
echo ""
if [[ "$TOTAL_FAILURES" -eq 0 ]]; then
    echo -e "  ${GREEN}every assertion held${NC}   evidence: $RESULTS"
else
    echo -e "  ${RED}${BOLD}${TOTAL_FAILURES} assertion(s) failed${NC}   evidence: $RESULTS"
fi
exit "$TOTAL_FAILURES"
