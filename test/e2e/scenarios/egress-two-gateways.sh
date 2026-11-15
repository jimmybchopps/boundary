# shellcheck shell=bash
# Two egress gateways (see _egress.sh): default, and second, which allows only second-tls. A
# ServiceEntry names the waypoint its host goes through. Through second, second-tls connects,
# and allowed-tls is refused: it's in default's list, not second's. Each waypoint has its own
# list.
# shellcheck source=test/e2e/scenarios/_egress.sh
source "${HERE}/scenarios/_egress.sh"

checks() {
  expect allow apps/x https://second-tls.e2e.test:443
  expect deny apps/x https://allowed-tls.e2e.test:443
}

install() {
  install_egress --set-json \
    'egress.gateways.second={"allowedHosts":{"tls":{"hosts":["second-tls.e2e.test"],"ports":[443],"protocol":"TLS"}}}'
  service_entry apps second-tls second TLS 443 hosts second-tls.e2e.test
  service_entry apps allowed-tls second TLS 443 hosts allowed-tls.e2e.test
}

extra() {
  check "two waypoints, each with its own Deployment" \
    gateway_field_is "$EGRESS_NAMESPACE" "default second" deployments '{.items[*].metadata.name}'
  check "accessLogs: second logged the request routed to it" \
    waypoint_logged second second-tls.e2e.test
  check "and default saw none of it" \
    waypoint_never_logged default second-tls.e2e.test
}
