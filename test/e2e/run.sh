#!/usr/bin/env bash
# boundary e2e tests on k3d: allowed traffic connects, refused traffic doesn't.
#
# Setup order (MESH=istio), as on a real cluster (CLAUDE.md, prerequisites):
#   cluster, the Gateway API CRDs (standard), Istio ambient, the gateway namespaces in the
#   mesh with their posture releases, and the external hosts the egress scenarios reach (Docker
#   containers on the cluster's network, named under e2e.test); then each scenario installs
#   this chart and removes it afterwards. Needs Docker and openssl (the scenarios'
#   certificates).
#
# Usage: test/e2e/run.sh <istio> [scenario...]
#   Normally run through `make e2e MESH=istio`, which installs the pinned tools, downloads the
#   pinned releases, and sets the variables below.
#
# Environment:
#   K3D, KUBECTL, HELM, ISTIOCTL     tool binaries (default: from PATH)
#   K3S_IMAGE, ISTIO_VERSION,
#   AGNHOST_IMAGE, CURL_IMAGE        pinned versions (set by the Makefile)
#   GATEWAY_API_CRDS                 the pinned Gateway API standard-install.yaml
#   POSTURE_CHART, POLICY_CRD        the pinned posture chart package, and the policy release's
#                                    PolicyExceptions CRD that posture's installs need
#   E2E_CLUSTER                      cluster name (default boundary-e2e)
#   E2E_KEEP=1                       keep the cluster afterwards (and stop at the first failing scenario)
#   E2E_REUSE=1                      use an existing cluster of that name (skips setup)
set -euo pipefail

MESH=${1:?usage: run.sh <istio> [scenario...]}
shift
[[ $MESH == istio ]] || { echo "unknown or unsupported mesh: $MESH (phase 1 supports istio)" >&2; exit 2; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CLUSTER=${E2E_CLUSTER:-boundary-e2e}
K3D=${K3D:-k3d}
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
ISTIOCTL=${ISTIOCTL:-istioctl}
: "${K3S_IMAGE:?set K3S_IMAGE (make e2e sets it)}"
: "${ISTIO_VERSION:?set ISTIO_VERSION}"
: "${AGNHOST_IMAGE:?set AGNHOST_IMAGE}"
: "${CURL_IMAGE:?set CURL_IMAGE}"
: "${GATEWAY_API_CRDS:?set GATEWAY_API_CRDS (make e2e sets it)}"
: "${POSTURE_CHART:?set POSTURE_CHART (make e2e sets it)}"
: "${POLICY_CRD:?set POLICY_CRD (make e2e sets it)}"
# The run's CA and certificates (lib.sh, make_ca and make_cert); removed on exit.
CERTS=$(mktemp -d)
export MESH HERE ROOT CLUSTER K3D KUBECTL HELM ISTIOCTL CERTS

# shellcheck source=test/e2e/lib.sh
source "$HERE/lib.sh"

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

if [[ ${E2E_REUSE:-0} == 1 ]]; then
  log "reusing cluster ${CLUSTER}"
  "$K3D" kubeconfig merge "$CLUSTER" --kubeconfig-switch-context >/dev/null
else
  delete_cluster
  create_cluster
  install_gateway_api
  install_istio
  gateway_namespaces
fi
# Every run (a reused cluster too): the certificates are new, so the hosts are restarted.
start_external

scenarios=("$@")
if [[ ${#scenarios[@]} -eq 0 ]]; then
  scenarios=(mtls-strict mtls-permissive
    ingress-https ingress-tls-settings ingress-cert-rotation ingress-passthrough ingress-tcp
    ingress-infrastructure
    egress-hosts egress-two-gateways egress-exit-nodes egress-infrastructure)
fi
for s in "${scenarios[@]}"; do
  run_scenario "$s"
  if [[ -n $KEPT_SCENARIO ]]; then break; fi
done

summary
