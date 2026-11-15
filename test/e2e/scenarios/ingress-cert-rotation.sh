# shellcheck shell=bash
# Certificate rotation (see _ingress.sh): replacing apps-tls with a new certificate takes effect
# without restarting or replacing the gateway's pods.
# shellcheck source=test/e2e/scenarios/_ingress.sh
source "${HERE}/scenarios/_ingress.sh"

install() {
  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml"
}

same_pods() { # same_pods <gateway> <gateway_pods output before>
  [[ $(gateway_pods "$1") == "$2" ]]
}

extra() {
  client_ready
  local apps=(client/x https api.apps.e2e.test 443 --cacert "$CA" https://api.apps.e2e.test/)
  check "before rotation: the original certificate is served" \
    retry subject_has boundary-e2e "${apps[@]}"
  local before
  before=$(gateway_pods https)
  ORG=rotated make_cert apps "*.apps.e2e.test"
  tls_secret "$INGRESS_NAMESPACE" apps-tls apps
  info "apps-tls replaced"
  check "after rotation: the new certificate is served" \
    retry subject_has rotated "${apps[@]}"
  check "rotation didn't restart or replace the gateway's pods" same_pods https "$before"
}
