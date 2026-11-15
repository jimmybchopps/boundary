# shellcheck shell=bash
# Shared by the egress scenarios (Istio only). The client x runs in namespace apps, in the mesh.
# The external hosts (lib.sh, start_external) are outside the cluster:
#   allowed-http.e2e.test, denied-http.e2e.test, second-http.e2e.test   ext-a, HTTP on 80
#   allowed-tls.e2e.test, denied-tls.e2e.test, second-tls.e2e.test     ext-tls, HTTPS on 443
#   ext-a and ext-b by address                                          HTTP on 8080
#
# Before the chart is installed there are no ServiceEntries, so the baseline reaches every
# target directly: the names resolve, the servers answer. install then installs the chart and
# writes ServiceEntries routed to a waypoint, shaped as posture renders them, so every request
# afterwards goes through the waypoint, and every refusal is the waypoint's.
#
# Not a scenario itself (the leading underscore keeps it out of run.sh's default list).

# shellcheck disable=SC2034 # read by run_scenario
SCENARIO_MESHES=(istio)

egress_setup() {
  namespace apps
  workload apps x 8080
}

setup() {
  egress_setup
}

teardown() {
  uninstall_boundary
}

# install_egress [helm args...]: the chart with values/egress.yaml, the TCP entry for ext-a, and
# any further arguments.
install_egress() {
  install_boundary minimal.yaml -f "$HERE/values/egress.yaml" \
    --set-json "egress.gateways.default.allowedHosts.tcp={\"addresses\":[\"${EXT_A}/32\"],\"ports\":[8080],\"protocol\":\"TCP\"}" \
    "$@"
}

# waypoint_logged <gateway> <text>: the waypoint logged a line containing text (accessLogs).
waypoint_logged() {
  retry gateway_logs_have "$EGRESS_NAMESPACE" "$1" "$2"
}

# waypoint_never_logged <gateway> <text>: the waypoint logged no line containing text.
waypoint_never_logged() {
  ! gateway_logs_have "$EGRESS_NAMESPACE" "$1" "$2"
}
