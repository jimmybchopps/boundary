# shellcheck shell=bash
# The default waypoint's allowedHosts (see _egress.sh): one entry per protocol, each matched on
# what that protocol can show. TLS by the server name: allowed-tls and denied-tls are the same
# server, only the SNI differs. HTTP by the Host header: allowed-http and denied-http are the
# same server. TCP by address: ext-a is allowed, ext-b isn't. Both requests of each pair reach
# the waypoint (their ServiceEntries route there); it refuses the one not in its list.
# shellcheck source=test/e2e/scenarios/_egress.sh
source "${HERE}/scenarios/_egress.sh"

checks() {
  expect allow apps/x https://allowed-tls.e2e.test:443
  expect allow apps/x allowed-http.e2e.test:80
  expect allow apps/x "${EXT_A}:8080"
  expect deny apps/x https://denied-tls.e2e.test:443
  expect deny apps/x denied-http.e2e.test:80
  expect deny apps/x "${EXT_B}:8080"
}

install() {
  # shellcheck disable=SC2119 # no extra helm arguments
  install_egress
  service_entry apps allowed-tls default TLS 443 hosts allowed-tls.e2e.test
  service_entry apps denied-tls default TLS 443 hosts denied-tls.e2e.test
  service_entry apps allowed-http default HTTP 80 hosts allowed-http.e2e.test
  service_entry apps denied-http default HTTP 80 hosts denied-http.e2e.test
  service_entry apps ext-a default TCP 8080 addresses "${EXT_A}/32"
  service_entry apps ext-b default TCP 8080 addresses "${EXT_B}/32"
}

extra() {
  # DNS capture and address auto-allocation (README, prerequisites): without them, a hostname
  # ServiceEntry gets no address and its traffic never reaches the waypoint.
  check "the hostname ServiceEntries got an address (ztunnel DNS capture and auto-allocation)" \
    retry service_entry_has_address apps/allowed-tls
  check "the waypoint has the allow-nothing policy and one policy per entry" \
    gateway_field_is "$EGRESS_NAMESPACE" \
    "allow-egress-via-default-to-http allow-egress-via-default-to-tcp allow-egress-via-default-to-tls deny-egress-via-default" \
    authorizationpolicies '{.items[*].metadata.name}'
  check "accessLogs: the waypoint logged the allowed TLS request" \
    waypoint_logged default allowed-tls.e2e.test
  check "accessLogs: the waypoint logged the allowed HTTP request" \
    waypoint_logged default allowed-http.e2e.test
}
