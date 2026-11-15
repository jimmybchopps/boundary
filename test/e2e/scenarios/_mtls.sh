# shellcheck shell=bash
# Shared by the mTLS scenarios (Istio only): "apps" is in the mesh and runs api and web; "plain"
# is outside it and runs x, whose requests are plaintext. Nothing but this chart's mesh-wide
# PeerAuthentication decides whether x reaches api: no NetworkPolicies, no authorization
# policies, and no namespace-level PeerAuthentication.
#
# Not a scenario itself (the leading underscore keeps it out of run.sh's default list).

# shellcheck disable=SC2034 # read by run_scenario
SCENARIO_MESHES=(istio)

setup() {
  namespace apps
  MESHED=0 namespace plain
  workload apps api 8080
  workload apps web 8080
  workload plain x 8080
}

teardown() {
  uninstall_boundary
}

# peer_authentication <name>: the mesh-wide PeerAuthentication exists in istio-system, carrying
# the chart's rule annotation.
peer_authentication() {
  [[ $("$KUBECTL" -n istio-system get peerauthentication "$1" \
    -o jsonpath='{.metadata.annotations.boundary\.posture\.dev/rule}') == mtls.mode ]]
}

no_peer_authentication() {
  ! "$KUBECTL" -n istio-system get peerauthentication "$1" >/dev/null 2>&1
}
