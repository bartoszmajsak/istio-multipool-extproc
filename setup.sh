#!/usr/bin/env bash
# Istio multi-pool ext_proc spike - cluster setup.
#
# Builds a kind cluster carrying Istio with the inference extension enabled, the
# Gateway API and GIE CRDs, two InferencePools with a stand-in endpoint picker
# each, and the routes under test. No KServe, no vLLM, no GPU, and no GIE
# controller - Istio writes InferencePool status itself, so the CRDs suffice.
#
# Usage:
#   ./setup.sh
#   ISTIO_VERSION=1.31.0 ./setup.sh
#   ./setup.sh --istio-version 1.30.2
#
# Everything is scoped to a kubeconfig next to this script, and the gateway is a
# ClusterIP service, so this cluster neither reads nor claims anything shared
# with the other kind clusters on the host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --istio-version) export ISTIO_VERSION="${2:?--istio-version needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1"; exit 2 ;;
    esac
done

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
docker_socket_guard

echo -e "${BOLD}Istio multi-pool ext_proc spike - setup${NC}"
echo "Istio:       $ISTIO_VERSION"
echo "Gateway API: $GATEWAY_API_VERSION    GIE CRDs: $GIE_VERSION"
echo "Cluster:     $CLUSTER_NAME           Namespace: $NS"
echo "Kubeconfig:  $KUBECONFIG"
echo "Split:       pool-a=${WEIGHT_A} pool-b=${WEIGHT_B} on ${HOSTNAME_}${SPLIT_PATH}${MODEL_PATH}"
echo "Pickers:     $EPP_IMAGE"
echo ""

for tool in kind kubectl helm docker python3; do
    command -v "$tool" >/dev/null || err "$tool not found in PATH"
done

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    info "Cluster $CLUSTER_NAME exists, reusing"
else
    info "Creating kind cluster $CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME" >/dev/null
fi
kind get kubeconfig --name "$CLUSTER_NAME" > "$KUBECONFIG"
ok "kubeconfig written to $KUBECONFIG"

for img in "$EPP_IMAGE" "$ECHO_IMAGE" "$K6_IMAGE"; do
    info "Fetching $img"
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
    # Best effort. Some of these manifests cannot be imported by kind - it asks
    # containerd for a content digest the local copy does not carry - so the
    # load is allowed to fail and the kubelet pulls instead. Setup already
    # fetches the Gateway API CRDs, the GIE CRDs and the Istio charts over the
    # network, so a registry is not a new dependency.
    kind load docker-image "$img" --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
done
ok "images ready"

info "Installing Gateway API CRDs $GATEWAY_API_VERSION"
kubectl apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null

info "Installing Gateway API Inference Extension CRDs $GIE_VERSION"
kubectl apply --server-side --force-conflicts \
    -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml" >/dev/null
kubectl wait --for=condition=Established --timeout=60s \
    crd/inferencepools.inference.networking.k8s.io >/dev/null \
    || err "InferencePool CRD not established"
ok "CRDs installed (no GIE controller - Istio writes InferencePool status itself)"

info "Installing Istio $ISTIO_VERSION"
helm repo add istio https://istio-release.storage.googleapis.com/charts 2>/dev/null || true
helm repo update istio >/dev/null
kubectl create namespace istio-system 2>/dev/null || true
# pilot-discovery takes server-side-apply ownership of this webhook's
# failurePolicy, which makes a re-run of the base chart fail on a field
# conflict. Dropping it lets the chart own it again; the chart recreates it.
kubectl delete validatingwebhookconfiguration istiod-default-validator --ignore-not-found >/dev/null 2>&1 || true
helm upgrade --install istio-base istio/base -n istio-system --version "$ISTIO_VERSION" --wait >/dev/null
helm upgrade --install istiod istio/istiod -n istio-system --version "$ISTIO_VERSION" \
    -f "$MANIFESTS/istiod-values.yaml" --wait >/dev/null
kubectl wait --timeout=180s -n istio-system deployment/istiod --for=condition=Available >/dev/null \
    || err "istiod not ready"
ok "istiod $ISTIO_VERSION ready with the inference extension enabled"

kubectl create namespace "$NS" 2>/dev/null || true

info "Loading the k6 burst script"
kubectl create configmap k6-scripts -n "$NS" --from-file="$SCRIPT_DIR/k6/burst.js" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

info "Applying workloads"
render_manifest "$MANIFESTS/workloads.yaml" | kubectl apply -f - >/dev/null

info "Applying gateway, pools and routes"
render_manifest "$MANIFESTS/routing.yaml" | kubectl apply -f - >/dev/null

info "Waiting for workloads"
for dep in backend-a backend-b epp-a epp-b client; do
    kubectl rollout status -n "$NS" "deployment/$dep" --timeout=180s >/dev/null \
        || err "$dep did not become ready"
done
ok "backends, pickers and client ready"

info "Waiting for the gateway"
kubectl wait --timeout=180s -n "$NS" "gateway/$GATEWAY_NAME" \
    --for=condition=Programmed >/dev/null || err "gateway not Programmed"
# Discovered from the Service rather than from status.addresses: the address is
# a ClusterIP here, and everything downstream dials the Service DNS name anyway.
GW_SVC=$(kubectl get svc -n "$NS" \
    -l "gateway.networking.k8s.io/gateway-name=${GATEWAY_NAME}" \
    -o jsonpath='{.items[0].metadata.name}')
[[ -n "$GW_SVC" ]] || err "no Service found for gateway $GATEWAY_NAME"
ok "gateway programmed, service ${GW_SVC}.${NS}.svc.cluster.local"

info "Waiting for the gateway proxy to match istiod $ISTIO_VERSION"
GW_IMAGE=$(wait_for_gateway_proxy 240) \
    || err "gateway proxy is still '${GW_IMAGE:-unknown}', not ${ISTIO_VERSION}; a run started now would be served by the previous proxy and stamped with the new version"
ok "gateway proxy: $(gateway_proxy_image)"

info "Waiting for both InferencePools to be accepted"
for pool in pool-a pool-b; do
    for _ in $(seq 1 60); do
        accepted=$(kubectl get inferencepool -n "$NS" "$pool" \
            -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
        [[ "$accepted" == "True" ]] && break
        sleep 2
    done
    [[ "$accepted" == "True" ]] || err "InferencePool $pool not Accepted (status: ${accepted:-none})"
done
ok "pool-a and pool-b accepted by the gateway"

# The route table is the subject of the whole spike, so setup does not finish
# until Envoy has actually loaded it. Polling for the compiled route also means
# no scenario below needs a settle sleep.
info "Waiting for the weighted route to reach Envoy"
wait_for_route "$SPLIT_ROUTE_NAME" 120 || err "route $SPLIT_ROUTE_NAME never appeared in the gateway's route table"
ok "route $SPLIT_ROUTE_NAME loaded"

mkdir -p "$RESULTS"
ENVOY_VERSION=$(envoy_admin server_info \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version","unknown"))' 2>/dev/null || echo unknown)
# Digests, not just tags. Tags are immutable by convention and by nobody's
# guarantee, and a staging registry can be re-pushed or garbage collected.
image_digest() {
    docker inspect "$1" --format '{{index .RepoDigests 0}}' 2>/dev/null \
        | sed 's/.*@//' || echo unknown
}

cat > "$RESULTS/versions.txt" <<EOF
istio=${ISTIO_VERSION}
envoy=${ENVOY_VERSION}
epp_image=${EPP_IMAGE}
epp_digest=$(image_digest "$EPP_IMAGE")
echo_image=${ECHO_IMAGE}
echo_digest=$(image_digest "$ECHO_IMAGE")
k6_image=${K6_IMAGE}
k6_digest=$(image_digest "$K6_IMAGE")
gateway_api=${GATEWAY_API_VERSION}
gie_crds=${GIE_VERSION}
cluster=${CLUSTER_NAME}
namespace=${NS}
split=${WEIGHT_A}:${WEIGHT_B}
EOF
ok "versions recorded in $RESULTS/versions.txt"
echo "  envoy: $ENVOY_VERSION"

echo ""
ok "Setup complete"
echo ""
echo "  ./validate.sh"
