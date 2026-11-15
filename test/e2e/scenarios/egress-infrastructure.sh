# shellcheck shell=bash
# The waypoint's infrastructure ConfigMap (see _egress.sh): Istio applies its patches to what it
# generates for the default waypoint (Deployment, PDB, and, with autoscaling, HPA, all named
# after the Gateway), and the waypoint's pods meet the policy chart's baked-in baseline (README,
# "Gateway pod compliance").
# shellcheck source=test/e2e/scenarios/_egress.sh
source "${HERE}/scenarios/_egress.sh"

checks() {
  expect allow apps/x https://allowed-tls.e2e.test:443
}

install() {
  # shellcheck disable=SC2119 # no extra helm arguments
  install_egress
  service_entry apps allowed-tls default TLS 443 hosts allowed-tls.e2e.test
}

extra() {
  local ns=$EGRESS_NAMESPACE
  check "deployment: 2 replicas (infrastructure.replicas)" \
    gateway_field_is "$ns" 2 deployment/default '{.spec.replicas}'
  check "podDisruptionBudget: minAvailable 1" \
    retry gateway_field_is "$ns" 1 pdb/default '{.spec.minAvailable}'
  check "no HorizontalPodAutoscaler while autoscaling is off" \
    bash -c "! '$KUBECTL' -n '$ns' get hpa/default"
  baseline_checks "$ns" default

  install_egress \
    --set egress.gateways.default.infrastructure.autoscaling.enabled=true \
    --set egress.gateways.default.infrastructure.autoscaling.minReplicas=2 \
    --set egress.gateways.default.infrastructure.autoscaling.maxReplicas=3
  check "autoscaling: a HorizontalPodAutoscaler with minReplicas 2 and maxReplicas 3" \
    retry gateway_field_is "$ns" "2 3" hpa/default '{.spec.minReplicas} {.spec.maxReplicas}'
}
