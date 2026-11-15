# shellcheck shell=bash
# The tls-passthrough gateway (see _ingress.sh): a TLSRoute reaches a workload that terminates TLS
# itself, with its own certificate; a TLSRoute from a namespace without the gateway's label isn't
# accepted.
# shellcheck source=test/e2e/scenarios/_ingress.sh
source "${HERE}/scenarios/_ingress.sh"

setup() {
  ingress_setup
  "$KUBECTL" label namespace apps ingress.boundary.posture.dev/tls-passthrough=true >/dev/null
  ORG=workload make_cert secure secure.passthrough.e2e.test
  tls_secret apps secure-tls secure
  tls_workload apps secure 8443 secure-tls
  route TLSRoute apps secure tls-passthrough tls "secure.passthrough.e2e.test" secure 8443
  route TLSRoute other secure tls-passthrough tls "other.passthrough.e2e.test" api 8080
}

install() {
  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml" -f "$HERE/values/passthrough.yaml"
}

extra() {
  client_ready
  local secure=(client/x tls-passthrough secure.passthrough.e2e.test 443 --cacert "$CA"
    https://secure.passthrough.e2e.test/)
  check "tls-passthrough: the labeled namespace's TLSRoute is accepted" \
    retry route_accepted TLSRoute apps/secure True
  check "tls-passthrough: it reaches the workload, which terminates TLS" \
    retry status_is 200 "${secure[@]}"
  check "tls-passthrough: the certificate is the workload's, not the gateway's" \
    subject_has "O=workload" "${secure[@]}"
  check "tls-passthrough: the unlabeled namespace's TLSRoute isn't accepted (NotAllowedByListeners)" \
    retry route_accepted TLSRoute other/secure False NotAllowedByListeners
}
