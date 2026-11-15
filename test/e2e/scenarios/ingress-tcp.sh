# shellcheck shell=bash
# The tcp gateway (see _ingress.sh, values/ingress.yaml): its listener db (5432) admits a
# TCPRoute only from namespace databases.
# shellcheck source=test/e2e/scenarios/_ingress.sh
source "${HERE}/scenarios/_ingress.sh"

setup() {
  ingress_setup
  namespace databases
  workload databases db 5432
  route TCPRoute databases db tcp db "" db 5432
  route TCPRoute other db tcp db "" api 8080
}

install() {
  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml" -f "$HERE/values/tcp.yaml"
}

extra() {
  check "tcp: the listener's namespace's TCPRoute is accepted" \
    retry route_accepted TCPRoute databases/db True
  check "tcp: it's reached through the gateway" \
    retry status_is 200 client/x tcp db.e2e.test 5432 http://db.e2e.test:5432/
  check "tcp: another namespace's TCPRoute isn't accepted (NotAllowedByListeners)" \
    retry route_accepted TCPRoute other/db False NotAllowedByListeners
}
