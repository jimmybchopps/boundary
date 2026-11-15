# shellcheck shell=bash
# The infrastructure ConfigMap (see _ingress.sh): Istio applies its patches to what it generates
# for the https gateway (replicas, disruption budget, and, with autoscaling, an autoscaler), and
# the gateway's pods meet the policy chart's baked-in baseline: seccomp RuntimeDefault from the
# ConfigMap, the rest as Istio generates it (README, "Gateway pod compliance").
# shellcheck source=test/e2e/scenarios/_ingress.sh
source "${HERE}/scenarios/_ingress.sh"

install() {
  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml"
}

extra() {
  local ns=$INGRESS_NAMESPACE
  check "deployment: 2 replicas (infrastructure.replicas)" \
    gateway_field_is "$ns" 2 deployment/https-istio '{.spec.replicas}'
  check "podDisruptionBudget: minAvailable 1" \
    retry gateway_field_is "$ns" 1 pdb/https-istio '{.spec.minAvailable}'
  check "no HorizontalPodAutoscaler while autoscaling is off" \
    bash -c "! '$KUBECTL' -n '$ns' get hpa/https-istio"
  baseline_checks "$ns" https

  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml" \
    --set ingress.gateways.https.infrastructure.autoscaling.enabled=true \
    --set ingress.gateways.https.infrastructure.autoscaling.minReplicas=2 \
    --set ingress.gateways.https.infrastructure.autoscaling.maxReplicas=3
  check "autoscaling: a HorizontalPodAutoscaler with minReplicas 2 and maxReplicas 3" \
    retry gateway_field_is "$ns" "2 3" hpa/https-istio '{.spec.minReplicas} {.spec.maxReplicas}'
}
