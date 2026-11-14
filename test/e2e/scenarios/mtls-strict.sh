# shellcheck shell=bash
# mtls.mode STRICT (examples/minimal.yaml): a pod outside the mesh can't reach a meshed pod,
# while meshed pods still reach each other (see _mtls.sh).
# shellcheck source=test/e2e/scenarios/_mtls.sh
source "${HERE}/scenarios/_mtls.sh"

install() {
  install_boundary minimal.yaml
}

checks() {
  expect deny plain/x api.apps:8080          # plaintext from outside the mesh
  expect allow apps/web api.apps:8080        # mesh client, mTLS
}

extra() {
  check "PeerAuthentication mtls-strict in istio-system, annotated mtls.mode" peer_authentication mtls-strict
}
