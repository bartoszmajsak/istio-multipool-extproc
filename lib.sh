# Shared configuration and helpers for the istio-multipool-extproc spike.
# Sourced by setup.sh, validate.sh and render-envoyfilter.sh.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()   { echo -e "${YELLOW}INFO${NC}: $1"; }
ok()     { echo -e "${GREEN}  OK${NC}: $1"; }
warn()   { echo -e "${CYAN}WARN${NC}: $1"; }
fail()   { echo -e "${RED}FAIL${NC}: $1"; }
err()    { echo -e "${RED}FAIL${NC}: $1"; exit 1; }
# Section headings are for whoever is debugging the harness. The default run
# prints three result lines and a verdict on the run, and nothing else.
# Progress, always on. The outage step alone takes over a minute, and a run that
# prints nothing until it finishes looks hung.
step()  { echo -e "${CYAN}==>${NC} $1"; }
substep() { echo "    $1"; }

header() { [[ -n "${VERBOSE:-}" ]] && echo -e "\n${BOLD}$1${NC}"; true; }

CLUSTER_NAME="${CLUSTER_NAME:-multipool-spike}"
NS="${NS:-multipool-spike}"
GATEWAY_CLASS="${GATEWAY_CLASS:-multipool-istio}"
GATEWAY_NAME="${GATEWAY_NAME:-multipool-gw}"

# Every kubectl/helm call is scoped to a file next to the scripts, so the eight
# other kind clusters on this host cannot be reached by accident and nothing
# here depends on the current context.
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/.kubeconfig}"

ISTIO_VERSION="${ISTIO_VERSION:-1.30.4}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"
GIE_VERSION="${GIE_VERSION:-v1.5.0}"

# No image is built by this spike. The endpoint pickers, the echo backend and
# the load generator are all published images that other people maintain, which
# is the point: nothing here reimplements a thing that already exists.
#
# Every tag is immutable. A floating tag would make a result uncitable - the
# whole artifact exists to be linked from an upstream issue, and "it reproduced
# on whatever :latest was that day" is not a reproduction. setup.sh additionally
# records the digest each tag resolved to, so a reader can check they ran the
# same bytes rather than the same name.
EPP_IMAGE="${EPP_IMAGE:-ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0}"

# Gateway API conformance's own echo server. It reflects request headers and
# names the pod that answered, so nothing here has to ship a backend.
ECHO_IMAGE="${ECHO_IMAGE:-gcr.io/k8s-staging-gateway-api/echo-basic:v20251106-v1.3.0-263-g47c3435c}"

K6_IMAGE="${K6_IMAGE:-grafana/k6:2.2.0}"

MANIFESTS="${SCRIPT_DIR}/manifests"
RESULTS="${RESULTS:-${SCRIPT_DIR}/results/istio-${ISTIO_VERSION}}"

# The topology mirrors the GIE conformance fixture
# GatewayWeightedAcrossTwoInferencePools
# (same hostname, same path, same replica count) so a result here is directly
# comparable to a conformance run that passes.
HOSTNAME_="${HOSTNAME_:-primary.example.com}"
SPLIT_PATH="/weighted-two-pools-test"
# The picker chooses a request-body parser by path suffix, so traffic has to
# look like inference traffic. The routes still match on their own prefix; this
# is appended to the request path only.
MODEL_PATH="${MODEL_PATH:-/v1/completions}"
BACKEND_REPLICAS="${BACKEND_REPLICAS:-3}"
WEIGHT_A="${WEIGHT_A:-9}"
WEIGHT_B="${WEIGHT_B:-1}"
REQUESTS="${REQUESTS:-100}"

# Envoy route names are "<namespace>.<httproute>.<rule-index>". score.py asserts
# against this one by name; render-envoyfilter.sh does not use it - it finds the
# routes to patch by their shape, so it works against routes named by somebody
# else's controller.
SPLIT_ROUTE_NAME="${NS}.split.0"
FIXED_ROUTE_NAME="${SPLIT_ROUTE_NAME}.fixed"

# A stale DOCKER_HOST pointing at a dead rootless socket breaks docker and kind
# even when the rootful daemon is healthy, and the error names the socket rather
# than the cause. The `:=` form does not help: it only fires when the variable is
# unset, and the failure mode is a variable that IS set and points at a dead
# socket.
docker_socket_guard() {
    if [[ -n "${DOCKER_HOST:-}" ]]; then
        local sock="${DOCKER_HOST#unix://}"
        if [[ ! -S "$sock" && -S /var/run/docker.sock ]]; then
            unset DOCKER_HOST
        fi
    fi
}

# Substitutes the TRAILING_UNDERSCORE placeholders in a manifest. Trailing
# rather than ${...} so the files stay valid YAML that kubectl can parse and a
# reader can diff against what was applied.
render_manifest() {
    local file="${1:?manifest required}"
    sed -e "s|NAMESPACE_|${NS}|g" \
        -e "s|EPPIMAGE_|${EPP_IMAGE}|g" \
        -e "s|ECHOIMAGE_|${ECHO_IMAGE}|g" \
        -e "s|K6IMAGE_|${K6_IMAGE}|g" \
        -e "s|REPLICAS_|${BACKEND_REPLICAS}|g" \
        -e "s|CLASS_|${GATEWAY_CLASS}|g" \
        -e "s|GATEWAY_|${GATEWAY_NAME}|g" \
        -e "s|HOSTNAME_|${HOSTNAME_}|g" \
        -e "s|WEIGHTA_|${WEIGHT_A}|g" \
        -e "s|WEIGHTB_|${WEIGHT_B}|g" \
        "$file"
}

# The newest Running and Ready gateway pod.
#
# `.items[0]` is not good enough: while the gateway rolls - which it does on
# every Istio version change - a Terminating pod can sort first, and every
# capture taken through it describes the PREVIOUS Istio version while the run is
# stamped with the new one. That is a silent wrong answer, not a failure.
gateway_pod() {
    kubectl get pod -n "$NS" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
        -o json 2>/dev/null | python3 -c '
import json, sys

# kubectl can hand back nothing under API pressure - during a scale-up, say.
# Failing loudly here takes down whatever caller needed the pod name; returning
# nothing lets the caller retry.
try:
    payload = json.load(sys.stdin)
except ValueError:
    raise SystemExit

best = None
for pod in payload.get("items", []):
    if pod["status"].get("phase") != "Running":
        continue
    if pod["metadata"].get("deletionTimestamp"):
        continue
    ready = any(c["type"] == "Ready" and c["status"] == "True"
                for c in pod["status"].get("conditions", []))
    if not ready:
        continue
    stamp = pod["metadata"]["creationTimestamp"]
    if best is None or stamp >= best[0]:
        best = (stamp, pod["metadata"]["name"])
if best:
    print(best[1])
'
}

# The image of the pod actually answering, not of the Deployment that will
# eventually produce it.
gateway_pod_image() {
    local pod
    pod="$(gateway_pod)"
    [[ -n "$pod" ]] || return 1
    kubectl get pod -n "$NS" "$pod" \
        -o jsonpath='{.spec.containers[?(@.name=="istio-proxy")].image}' 2>/dev/null
}

# Envoy's admin API read from inside the gateway pod. istioctl is deliberately
# not used anywhere in this spike: a client skewed from istiod returns empty
# JSON with exit status 0, which reads as "the config is missing" and has
# already cost this investigation a day. The pod's own admin port cannot skew.
envoy_admin() {
    local path="${1:?path required}" pod
    pod="$(gateway_pod)"
    [[ -n "$pod" ]] || { echo ""; return 1; }
    kubectl exec -n "$NS" "$pod" -c istio-proxy -- \
        curl -s --max-time 10 "localhost:15000/${path}" 2>/dev/null
}

# Captures to a file and refuses to return an empty one. Every downstream
# assertion reads these files, and an empty capture would make each of them
# vacuously true.
capture() {
    local path="${1:?path required}" out="${2:?out file required}"
    mkdir -p "$(dirname "$out")"
    envoy_admin "$path" > "$out" || true
    [[ -s "$out" ]] || return 1
    return 0
}

# Poll until a predicate over the live route config holds, instead of sleeping.
# xDS convergence has no readiness condition to wait on, but it does have an
# observable end state, and polling for that end state doubles as the evidence
# capture. Sleeps here would be both slower and weaker.
wait_for_route() {
    local want="${1:?route name required}" timeout="${2:-60}" deadline
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if envoy_admin "config_dump?resource=dynamic_route_configs" \
            | grep -q "\"${want}\""; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_route_gone() {
    local gone="${1:?route name required}" timeout="${2:-60}" deadline
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if ! envoy_admin "config_dump?resource=dynamic_route_configs" \
            | grep -q "\"${gone}\""; then
            return 0
        fi
        sleep 1
    done
    return 1
}

gateway_deployment() {
    kubectl get deploy -n "$NS" -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

gateway_proxy_image() {
    local deploy
    deploy="$(gateway_deployment)"
    [[ -n "$deploy" ]] || return 1
    kubectl get deploy -n "$NS" "$deploy" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="istio-proxy")].image}' 2>/dev/null
}

# Waits until the gateway is running the proxy that belongs to the istiod now
# installed, and until that pod has finished rolling.
#
# Changing ISTIO_VERSION on an existing cluster upgrades istiod first; istiod's
# deployment controller then rewrites the gateway Deployment, and the pod rolls
# some seconds later. A run started in that window is served by the OLD proxy
# while every result is stamped with the NEW Istio version - the exact
# mis-attribution this spike cannot afford - and the old pod's name also makes
# access-log captures come back empty halfway through.
wait_for_gateway_proxy() {
    local timeout="${1:-240}" deadline deploy image
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        image="$(gateway_proxy_image || true)"
        if [[ "$image" == *":${ISTIO_VERSION}" ]]; then
            deploy="$(gateway_deployment)"
            if kubectl rollout status -n "$NS" "deployment/${deploy}" \
                --timeout=120s >/dev/null 2>&1; then
                # The Deployment being updated and rolled out is not the same as
                # the pod this spike will read from being the new one, so the
                # serving pod's own image is what settles it.
                [[ "$(gateway_pod_image || true)" == *":${ISTIO_VERSION}" ]] && return 0
            fi
        fi
        sleep 2
    done
    echo "$image"
    return 1
}

# The newest Running and Ready client pod, for the same reason gateway_pod is
# careful: `.items[0]` can be a Terminating pod during a rollout, and every
# kubectl exec through it fails. setup.sh rolls this deployment whenever the
# image tag changes, so the window is not hypothetical.
client_pod() {
    kubectl get pod -n "$NS" -l app=client -o json 2>/dev/null | python3 -c '
import json, sys

try:
    payload = json.load(sys.stdin)
except ValueError:
    raise SystemExit

best = None
for pod in payload.get("items", []):
    if pod["status"].get("phase") != "Running":
        continue
    if pod["metadata"].get("deletionTimestamp"):
        continue
    if not any(c["type"] == "Ready" and c["status"] == "True"
               for c in pod["status"].get("conditions", [])):
        continue
    stamp = pod["metadata"]["creationTimestamp"]
    if best is None or stamp >= best[0]:
        best = (stamp, pod["metadata"]["name"])
if best:
    print(best[1])
'
}

# How many endpoints Envoy currently has for a pool's cluster.
#
# Read from the proxy rather than from Kubernetes: what decides whether a
# request can be served is the data plane's endpoint set, and it lags the API
# server. Waiting on the wrong one races.
pool_endpoints() {
    local pool="${1:?pool required}"
    envoy_admin "clusters?format=json" | python3 -c '
import json, sys

pool = sys.argv[1]
try:
    dump = json.load(sys.stdin)
except ValueError:
    print(-1)
    raise SystemExit
for cluster in dump.get("cluster_statuses", []):
    service = cluster.get("name", "").split("||")[-1].split(".")[0]
    if service.startswith(pool + "-ip-"):
        print(len(cluster.get("host_statuses", [])))
        break
else:
    print(-1)
' "$pool"
}

wait_pool_endpoints() {
    local pool="${1:?pool required}" want="${2:?count required}" timeout="${3:-180}"
    local deadline got
    deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        got="$(pool_endpoints "$pool")"
        [[ "$got" == "$want" ]] && return 0
        sleep 2
    done
    echo "$got"
    return 1
}

# Empties a pool for real, by scaling its model servers away.
#
# This is the condition the original incident was: a canary member with no ready
# pods. A real endpoint picker with no endpoints returns ImmediateResponse 503
# per the EPP protocol, which is the thing the outage scenarios are about, and
# there is no way to ask a real picker to pretend. It also means the pool's
# cluster empties at the same time - the two are coupled by design, since Istio
# builds the cluster's EDS from the same selector - so the scenarios assert on
# the weight share that dies rather than trying to separate them.
drain_pool() {
    local pool="${1:?pool required}" backend
    backend="backend-${pool#pool-}"
    kubectl scale deploy -n "$NS" "$backend" --replicas=0 >/dev/null
    wait_pool_endpoints "$pool" 0 120 \
        || err "$pool still has endpoints in the proxy after scaling $backend to zero"
}

fill_pool() {
    local pool="${1:?pool required}" backend
    backend="backend-${pool#pool-}"
    kubectl scale deploy -n "$NS" "$backend" --replicas="$BACKEND_REPLICAS" >/dev/null
    kubectl rollout status -n "$NS" "deploy/$backend" --timeout=180s >/dev/null \
        || err "$backend did not come back"
    wait_pool_endpoints "$pool" "$BACKEND_REPLICAS" 180 \
        || err "$pool did not regain its endpoints in the proxy"
}
