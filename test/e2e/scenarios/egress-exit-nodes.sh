# shellcheck shell=bash
# exitNodes (see _egress.sh): with exitNodes set, the default waypoint's pods run only on the
# labeled node (the cluster's agent), and an allowed host still connects through it.
# shellcheck source=test/e2e/scenarios/_egress.sh
source "${HERE}/scenarios/_egress.sh"

EXIT_NODE="k3d-${CLUSTER}-agent-0"
EXIT_LABEL=e2e.boundary.posture.dev/exit

setup() {
  egress_setup
  quiet "$KUBECTL" label node "$EXIT_NODE" "${EXIT_LABEL}=true" --overwrite
}

checks() {
  expect allow apps/x https://allowed-tls.e2e.test:443
  expect deny apps/x https://denied-tls.e2e.test:443
}

install() {
  install_egress --set-json "egress.gateways.default.exitNodes={\"${EXIT_LABEL}\":\"true\"}"
  service_entry apps allowed-tls default TLS 443 hosts allowed-tls.e2e.test
  service_entry apps denied-tls default TLS 443 hosts denied-tls.e2e.test
}

extra() {
  check "every waypoint pod runs on the exit node (${EXIT_NODE})" \
    every_pod_is "$EGRESS_NAMESPACE" default "$EXIT_NODE" '{.spec.nodeName}'
  check "accessLogs: the request went through the pinned waypoint" \
    waypoint_logged default allowed-tls.e2e.test
}

teardown() {
  uninstall_boundary
  quiet "$KUBECTL" label node "$EXIT_NODE" "${EXIT_LABEL}-"
}
