# shellcheck shell=bash
# Shared by the ingress scenarios (Istio only). This chart's gateways run in the ingress
# namespace with the certificates apps-tls (*.apps.e2e.test) and internal-tls
# (*.internal.e2e.test), from the run's CA. Namespaces:
#   apps     in the mesh, labeled ingress.boundary.posture.dev/https: "true"; runs api, with an
#            HTTPRoute for api.apps.e2e.test and api.internal.e2e.test
#   other    in the mesh, not labeled; runs api, with an HTTPRoute for other.apps.e2e.test
#   client   outside the mesh; runs x, the client, as a request from outside the cluster would be
# The chart is installed from examples/minimal.yaml with values/ingress.yaml (and, per scenario,
# values/passthrough.yaml or values/tcp.yaml).
#
# There is no gateway before the chart is installed, so the connection baseline has nothing to
# check: checks is empty, and every check is in extra, each refusal next to the request that
# shows the same path works.
#
# Not a scenario itself (the leading underscore keeps it out of run.sh's default list).

# shellcheck disable=SC2034 # read by run_scenario
SCENARIO_MESHES=(istio)

# The CA's path in the client container (client_ready).
CA=/tmp/ca.crt

ingress_setup() {
  make_cert apps "*.apps.e2e.test"
  make_cert internal "*.internal.e2e.test"
  tls_secret "$INGRESS_NAMESPACE" apps-tls apps
  tls_secret "$INGRESS_NAMESPACE" internal-tls internal
  namespace apps
  "$KUBECTL" label namespace apps ingress.boundary.posture.dev/https=true >/dev/null
  namespace other
  MESHED=0 namespace client
  workload apps api 8080
  workload other api 8080
  workload client x 8080
  route HTTPRoute apps api https "" "api.apps.e2e.test api.internal.e2e.test" api 8080
  route HTTPRoute other api https "" "other.apps.e2e.test" api 8080
}

setup() {
  ingress_setup
}

checks() {
  :
}

teardown() {
  uninstall_boundary
  "$KUBECTL" -n "$INGRESS_NAMESPACE" delete secret apps-tls internal-tls --ignore-not-found >/dev/null
}

# client_ready: gives the client the CA. Runs in extra, after restart_workloads replaced the
# client's pod.
client_ready() {
  copy_to client/x "$CERTS/ca.crt" "$CA"
}
