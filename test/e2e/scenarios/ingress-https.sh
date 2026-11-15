# shellcheck shell=bash
# The https gateway (see _ingress.sh): a labeled namespace's HTTPRoute serves traffic with the
# gateway's certificate, an unlabeled namespace's route isn't accepted, HTTP redirects to HTTPS,
# and the gateway logs the request (accessLogs).
# shellcheck source=test/e2e/scenarios/_ingress.sh
source "${HERE}/scenarios/_ingress.sh"

install() {
  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml"
}

extra() {
  client_ready
  check "https: the labeled namespace's HTTPRoute is accepted" \
    retry route_accepted HTTPRoute apps/api True
  check "https: it serves traffic from outside the mesh, and the certificate validates" \
    retry status_is 200 client/x https api.apps.e2e.test 443 --cacert "$CA" https://api.apps.e2e.test/
  check "https: the unlabeled namespace's HTTPRoute isn't accepted (NotAllowedByListeners)" \
    retry route_accepted HTTPRoute other/api False NotAllowedByListeners
  check "https: so its hostname gets a 404" \
    status_is 404 client/x https other.apps.e2e.test 443 --cacert "$CA" https://other.apps.e2e.test/
  check "http: every request gets a 301 to https" \
    retry redirects_to https://api.apps.e2e.test/ client/x https api.apps.e2e.test 80 http://api.apps.e2e.test/
  check "accessLogs: the gateway logged the request" \
    retry gateway_logs_have "$INGRESS_NAMESPACE" https api.apps.e2e.test
}
