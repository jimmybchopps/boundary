# shellcheck shell=bash
# mtls.mode PERMISSIVE (examples/permissive.yaml): a pod outside the mesh still reaches a meshed
# pod (see _mtls.sh). Ambient is permissive without the chart too, so the connections alone
# prove little; extra checks that the chart's mtls-permissive is what's in place.
# shellcheck source=test/e2e/scenarios/_mtls.sh
source "${HERE}/scenarios/_mtls.sh"

install() {
  install_boundary permissive.yaml -f "$HERE/values/no-ingress.yaml"
}

checks() {
  expect allow plain/x api.apps:8080         # plaintext, PERMISSIVE
  expect allow apps/web api.apps:8080        # mesh client, mTLS
}

extra() {
  check "PeerAuthentication mtls-permissive in istio-system, annotated mtls.mode" peer_authentication mtls-permissive
  check "no PeerAuthentication mtls-strict" no_peer_authentication mtls-strict
}
