#!/usr/bin/env bash
# boundary's integration run (docs/PLAN.md, phase 4): the whole stack on one cluster, in the
# documented install order (README, "Install order"), under the policy chart's defaults
# enforced, then a clean uninstall in reverse.
#
# Install order:
#   cluster (Calico, so posture's NetworkPolicies are enforced), the Gateway API CRDs, the
#   external hosts, Istio's CRDs (base), the policy chart, posture in istio-system, istiod,
#   istio-cni and ztunnel, the gateway namespaces with posture, the TLS Secret, the application
#   namespaces (posture first, then their pods), boundary.
#
# Namespaces:
#   shop    in the mesh, labeled for the https gateway; runs api (8080), routed as
#           api.shop.e2e.test. posture: the ingress-gateway source on 8080.
#   apps    in the mesh; runs x. posture asks for allowed-tls and denied-tls through the default
#           egress waypoint; boundary's list has allowed-tls only.
#   other   in the mesh; runs x. posture asks for no hosts.
#   client  outside the mesh; runs x, a client from outside the cluster. posture: egress to the
#           ingress gateways only.
# Each application namespace gets an exceptions-only posture first, so its pods are admitted
# and the baseline (every refused path connects before anything is installed) can run; then its
# own posture.
#
# Usage: test/e2e/integration.sh <istio>
#   Normally run through `make e2e-integration MESH=istio`, which sets the variables run.sh
#   takes plus CALICO_VERSION, POLICY_CHART, and the Istio images.
#   E2E_CLUSTER   cluster name (default boundary-integration)
#   E2E_KEEP=1    keep the cluster afterwards, and skip the uninstall if anything failed before
#                 it, so the failing state can be inspected
# There's no E2E_REUSE: the run ends by uninstalling everything, so it always starts fresh.
set -euo pipefail

MESH=${1:?usage: integration.sh <istio>}
[[ $MESH == istio ]] || { echo "unknown or unsupported mesh: $MESH (phase 4 supports istio)" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CLUSTER=${E2E_CLUSTER:-boundary-integration}
K3D=${K3D:-k3d}
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
ISTIOCTL=${ISTIOCTL:-istioctl}
: "${K3S_IMAGE:?set K3S_IMAGE (make e2e-integration sets it)}"
: "${CALICO_VERSION:?set CALICO_VERSION}"
: "${ISTIO_VERSION:?set ISTIO_VERSION}"
: "${ISTIO_PILOT_IMAGE:?set ISTIO_PILOT_IMAGE}"
: "${ISTIO_PROXY_IMAGE:?set ISTIO_PROXY_IMAGE}"
: "${ISTIO_ZTUNNEL_IMAGE:?set ISTIO_ZTUNNEL_IMAGE}"
: "${AGNHOST_IMAGE:?set AGNHOST_IMAGE}"
: "${CURL_IMAGE:?set CURL_IMAGE}"
: "${GATEWAY_API_CRDS:?set GATEWAY_API_CRDS}"
: "${POSTURE_CHART:?set POSTURE_CHART}"
: "${POLICY_CRD:?set POLICY_CRD}"
: "${POLICY_CHART:?set POLICY_CHART}"
CERTS=$(mktemp -d)
# Calico instead of flannel, and no Istio platform setting, as in posture's harness (lib.sh,
# create_cluster and install_istio).
CNI=calico
ISTIO_PLATFORM=""
export MESH HERE ROOT CLUSTER K3D KUBECTL HELM ISTIOCTL CERTS CNI ISTIO_PLATFORM

# shellcheck source=test/e2e/lib.sh
source "$HERE/lib.sh"

KEEP_STATE=0

teardown() {
  rm -rf "$CERTS"
  if [[ ${E2E_KEEP:-0} == 1 ]]; then
    log "keeping cluster ${CLUSTER} (E2E_KEEP=1); delete it with: $K3D cluster delete ${CLUSTER}"
    info "and the external hosts with: docker rm -f ${CLUSTER}-ext-a ${CLUSTER}-ext-b ${CLUSTER}-ext-tls"
  else
    stop_external
    delete_cluster
  fi
}
trap teardown EXIT

APP_NAMESPACES=(shop apps other client)
# The CA's path in the client container (copy_to).
CA=/tmp/ca.crt

# ---------------------------------------------------------------------------------------------
# Install, in the documented order

platform() {
  delete_cluster
  create_cluster
  install_gateway_api
  start_external
  install_istio_base
  install_policy
  log "posture in istio-system (profile istio-system)"
  posture_release istio-system istio-system.yaml \
    --set-json "profiles.istio-system.settings.apiServerCidrs=[\"$(k3d_network_cidr)\"]"
  install_istio_control_plane
  log "the gateway namespaces, in the mesh, each with its posture profile"
  local ns
  for ns in "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    "$KUBECTL" create namespace "$ns" >/dev/null
    "$KUBECTL" label namespace "$ns" istio.io/dataplane-mode=ambient >/dev/null
    posture_release "$ns" "${ns}.yaml"
  done
  make_cert apps "*.shop.e2e.test"
  tls_secret "$INGRESS_NAMESPACE" apps-tls apps
  info "${INGRESS_NAMESPACE}: Secret apps-tls (*.shop.e2e.test)"
}

applications() {
  log "the application namespaces (exceptions-only posture, then their pods)"
  local ns
  for ns in "${APP_NAMESPACES[@]}"; do
    if [[ $ns == client ]]; then MESHED=0 namespace "$ns"; else namespace "$ns"; fi
    posture_release "$ns" exceptions-only.yaml
  done
  "$KUBECTL" label namespace shop ingress.boundary.posture.dev/https=true >/dev/null
  workload shop api 8080
  workload apps x 8080
  workload other x 8080
  workload client x 8080
  if ! wait_ready; then
    for ns in "${APP_NAMESPACES[@]}"; do refused_pods "$ns"; done
    die "the application pods didn't start"
  fi
}

# Each refused path, before anything that refuses it is installed: it must connect, so its deny
# later can't pass for the wrong reason (a name that doesn't resolve, a server that's down).
baseline() {
  log "baseline (no application posture, no boundary)"
  expect allow apps/x https://allowed-tls.e2e.test:443
  expect deny apps/x https://denied-tls.e2e.test:443
  expect deny other/x https://allowed-tls.e2e.test:443
  run_checks baseline
}

application_posture() {
  log "each application namespace's own posture"
  local ns
  for ns in "${APP_NAMESPACES[@]}"; do posture_release "$ns" "${ns}.yaml"; done
}

install_chart() {
  log "boundary"
  route HTTPRoute shop api https "" "api.shop.e2e.test" api 8080
  # In a subshell with errexit on, so a failed install is reported and the run goes on to the
  # summary instead of stopping here.
  local status=0
  set +e
  (set -e; install_boundary minimal.yaml -f "$HERE/values/integration/boundary.yaml")
  status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    refused_pods "$INGRESS_NAMESPACE"
    refused_pods "$EGRESS_NAMESPACE"
    record FAIL "boundary installed, and its gateways and waypoints became ready"
    return 0
  fi
  record PASS "boundary installed, and its gateways and waypoints became ready"
  restart_workloads
  copy_to client/x "$CERTS/ca.crt" "$CA"
}

# ---------------------------------------------------------------------------------------------
# Checks

# no_refused_pods <namespace>: no pod there was refused at admission (FailedCreate events).
no_refused_pods() {
  [[ -z $("$KUBECTL" -n "$1" get events --field-selector reason=FailedCreate -o name 2>/dev/null) ]]
}

# gateway_available <namespace> <gateway>: the Deployment Istio generated for it is available.
gateway_available() {
  local d
  d=$(gateway_deployment "$1" "$2") || return 1
  "$KUBECTL" -n "$1" wait --for=condition=Available "$d" --timeout=10s
}

# only_profile_exception <namespace> <component>: the namespace's posture-exceptions holds one
# exception, disallow-mesh-opt-out, for the pods labeled with that component (the posture
# profile's), and nothing else.
only_profile_exception() {
  local got
  got=$("$KUBECTL" -n "$1" get policyexceptions posture-exceptions \
    -o jsonpath='{range .spec.exceptions[*]}{.policy.name}={range .workloads[*]}{.matchLabels.app\.kubernetes\.io/component}{end};{end}') || return 1
  [[ $got == "disallow-mesh-opt-out=$2;" ]]
}

admission_checks() {
  local entry ns gw component
  for entry in "$INGRESS_NAMESPACE https ingress-gateway" "$EGRESS_NAMESPACE default egress-waypoint"; do
    read -r ns gw component <<<"$entry"
    check "admission: ${ns}/${gw}'s pods are admitted and its Deployment is available" \
      gateway_available "$ns" "$gw"
    check "admission: no pod in ${ns} was refused" \
      no_refused_pods "$ns"
    check "admission: ${ns}/${gw}'s pods carry app.kubernetes.io/name=${gw} and component=${component}" \
      every_pod_is "$ns" "$gw" "${gw}/${component}" \
      '{.metadata.labels.app\.kubernetes\.io/name}/{.metadata.labels.app\.kubernetes\.io/component}'
    check "admission: ${ns}'s posture-exceptions holds only the profile's disallow-mesh-opt-out exception" \
      only_profile_exception "$ns" "$component"
    # The two audit-default policies the run doesn't enforce yet (policy.yaml), checked on the
    # pods directly: both come from the infrastructure ConfigMap.
    check "admission: ${ns}/${gw}'s pods set automountServiceAccountToken: false (disallow-automount-service-account-token)" \
      every_pod_is "$ns" "$gw" false '{.spec.automountServiceAccountToken}'
    check "admission: ${ns}/${gw}'s istio-proxy has a liveness probe on /healthz/ready (require-probes)" \
      every_pod_is "$ns" "$gw" /healthz/ready '{.spec.containers[?(@.name=="istio-proxy")].livenessProbe.httpGet.path}'
  done
  check "admission: boundary's redirect route (no hostnames) is admitted in ${INGRESS_NAMESPACE} and accepted" \
    retry route_accepted HTTPRoute "${INGRESS_NAMESPACE}/redirect-http-to-https-https" True
}

# liveness_checks: at the end of the run, no gateway or waypoint proxy has been restarted, so its
# liveness probe didn't fail while it was serving.
liveness_checks() {
  local entry ns gw
  for entry in "$INGRESS_NAMESPACE https" "$EGRESS_NAMESPACE default"; do
    read -r ns gw <<<"$entry"
    check "liveness: ${ns}/${gw}'s istio-proxy was never restarted" \
      every_pod_is "$ns" "$gw" 0 '{.status.containerStatuses[?(@.name=="istio-proxy")].restartCount}'
  done
}

ingress_checks() {
  check "ingress: shop's HTTPRoute is accepted by the https gateway" \
    retry route_accepted HTTPRoute shop/api True
  check "ingress: client reaches https://api.shop.e2e.test through https (200, certificate validates)" \
    retry status_is 200 client/x https api.shop.e2e.test 443 --cacert "$CA" https://api.shop.e2e.test/
  check "ingress: http://api.shop.e2e.test gets a 301 to https" \
    retry redirects_to https://api.shop.e2e.test/ client/x https api.shop.e2e.test 80 http://api.shop.e2e.test/
}

egress_checks() {
  ALLOWS=()
  DENIES=()
  expect allow apps/x https://allowed-tls.e2e.test:443
  expect deny apps/x https://denied-tls.e2e.test:443
  expect deny other/x https://allowed-tls.e2e.test:443
  run_checks chart
  check "egress: apps' request for allowed-tls went through the default waypoint (its access log)" \
    retry gateway_logs_have "$EGRESS_NAMESPACE" default allowed-tls.e2e.test
  check "egress: apps' request for denied-tls reached the default waypoint, which refused it" \
    retry gateway_logs_have "$EGRESS_NAMESPACE" default denied-tls.e2e.test
}

# httproute <namespace> <name> [hostname...]: an HTTPRoute manifest for the https gateway.
httproute() {
  local ns=$1 name=$2 hosts="" h
  shift 2
  for h in "$@"; do hosts+="
    - ${h}"; done
  cat <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: ${name}, namespace: ${ns} }
spec:
  parentRefs:
    - { name: https, namespace: ${INGRESS_NAMESPACE} }
  ${hosts:+hostnames: ${hosts}}
  rules:
    - backendRefs:
        - { name: api, port: 8080 }
EOF
}

route_rule_checks() {
  check "route rule: shop's route for its own hostname (api.shop.e2e.test) was admitted" \
    "$KUBECTL" -n shop get httproute api
  check "route rule: a route in shop claiming api.other.e2e.test is refused (restrict-route-hostnames)" \
    admission_refused restrict-route-hostnames < <(httproute shop claim-other api.other.e2e.test)
  check "route rule: a route in shop with no hostnames is refused (restrict-route-hostnames)" \
    admission_refused restrict-route-hostnames < <(httproute shop claim-all)
}

# ---------------------------------------------------------------------------------------------
# Uninstall, in reverse order

# nothing_left <kubectl get args...>: the query lists nothing.
nothing_left() {
  [[ -z $("$KUBECTL" get "$@" -o name 2>/dev/null) ]]
}

# namespaces_gone <namespace>...: each is deleted within 120 seconds (none stuck Terminating).
namespaces_gone() {
  local ns
  for ns in "$@"; do "$KUBECTL" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true; done
  for ns in "$@"; do "$KUBECTL" wait --for=delete "namespace/$ns" --timeout=120s >/dev/null 2>&1 || return 1; done
}

uninstall_checks() {
  log "uninstall, in reverse order"
  uninstall_boundary
  check "uninstall: no boundary objects are left" \
    nothing_left gateways,httproutes,authorizationpolicies,peerauthentications,telemetries,envoyfilters,configmaps \
    -A -l app.kubernetes.io/instance=boundary
  check "uninstall: the Deployments Istio generated for the gateways and waypoints are gone" \
    nothing_left deployments -A -l gateway.networking.k8s.io/gateway-name
  local ns
  for ns in "${APP_NAMESPACES[@]}" "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    "$HELM" uninstall posture -n "$ns" --wait >/dev/null 2>&1 || true
  done
  check "uninstall: the application and gateway namespaces are deleted (none stuck Terminating)" \
    namespaces_gone "${APP_NAMESPACES[@]}" "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"
  NAMESPACES=()
  local release
  for release in ztunnel istiod; do "$HELM" uninstall "$release" -n istio-system --wait >/dev/null 2>&1 || true; done
  "$HELM" uninstall istio-cni -n kube-system --wait >/dev/null 2>&1 || true
  "$HELM" uninstall posture -n istio-system --wait >/dev/null 2>&1 || true
  "$HELM" uninstall policy -n policy --wait >/dev/null 2>&1 || true
  "$HELM" uninstall istio-base -n istio-system --wait >/dev/null 2>&1 || true
  check "uninstall: istio-system and policy are deleted (none stuck Terminating)" \
    namespaces_gone istio-system policy
  check "uninstall: no Helm releases are left" \
    nothing_left_helm
}

nothing_left_helm() {
  [[ -z $("$HELM" list -A -q 2>/dev/null) ]]
}

# ---------------------------------------------------------------------------------------------

platform
applications
baseline
application_posture
install_chart

log "checks"
admission_checks
ingress_checks
egress_checks
route_rule_checks
liveness_checks

if [[ $FAILED -gt 0 ]]; then
  dump_state
  for ns in "${APP_NAMESPACES[@]}" "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE" istio-system; do
    refused_pods "$ns"
  done
  if [[ ${E2E_KEEP:-0} == 1 ]]; then
    KEEP_STATE=1
    info "keeping everything installed for inspection (E2E_KEEP=1); skipping the uninstall"
  fi
fi
if [[ $KEEP_STATE == 0 ]]; then uninstall_checks; fi

summary
