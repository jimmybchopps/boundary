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

field_is() { # field_is <want> <kubectl get args...> <jsonpath>
  local want=$1 got
  shift
  got=$("$KUBECTL" -n "$INGRESS_NAMESPACE" get "${@:1:$#-1}" -o "jsonpath=${!#}" 2>/dev/null) || return 1
  [[ $got == "$want" ]]
}

# all_equal <want> <jsonpath template>: the template, printed once per line, gives <want> on
# every line, and on at least one.
all_equal() {
  local want=$1 selector=gateway.networking.k8s.io/gateway-name=https lines line
  [[ -n $("$KUBECTL" -n "$INGRESS_NAMESPACE" get pods -l "$selector" -o name) ]] || return 1
  lines=$("$KUBECTL" -n "$INGRESS_NAMESPACE" get pods -l "$selector" -o "jsonpath=$2") || return 1
  while IFS= read -r line; do [[ $line == "$want" ]] || return 1; done <<<"$lines"
}

# every_pod_is <want> <field jsonpath>: that field of each of the https gateway's pods is <want>.
every_pod_is() {
  all_equal "$1" "{range .items[*]}$2{\"\\n\"}{end}"
}

# every_container_is <want> <field jsonpath>: that field of each container of those pods is <want>.
every_container_is() {
  all_equal "$1" "{range .items[*]}{range .spec.containers[*]}$2{\"\\n\"}{end}{end}"
}

extra() {
  check "deployment: 2 replicas (infrastructure.replicas)" \
    field_is 2 deployment/https-istio '{.spec.replicas}'
  check "podDisruptionBudget: minAvailable 1" \
    retry field_is 1 pdb/https-istio '{.spec.minAvailable}'
  check "no HorizontalPodAutoscaler while autoscaling is off" \
    bash -c "! '$KUBECTL' -n '$INGRESS_NAMESPACE' get hpa/https-istio"
  # The baked-in baseline, as the generated pods run.
  check "baseline: pod seccompProfile RuntimeDefault (restrict-seccomp, from the ConfigMap)" \
    every_pod_is RuntimeDefault '{.spec.securityContext.seccompProfile.type}'
  check "baseline: no host namespaces (disallow-host-namespaces)" \
    every_pod_is "//" '{.spec.hostNetwork}/{.spec.hostPID}/{.spec.hostIPC}'
  check "baseline: no hostPath volumes (disallow-host-path)" \
    every_pod_is "" '{.spec.volumes[*].hostPath}'
  check "baseline: only safe sysctls (restrict-sysctls)" \
    every_pod_is "net.ipv4.ip_unprivileged_port_start" '{.spec.securityContext.sysctls[*].name}'
  check "baseline: no privilege escalation (disallow-privilege-escalation)" \
    every_container_is false '{.securityContext.allowPrivilegeEscalation}'
  check "baseline: not privileged (disallow-privileged-containers)" \
    every_container_is false '{.securityContext.privileged}'
  check "baseline: drop ALL, add nothing (require-drop-all-capabilities)" \
    every_container_is '["ALL"]/' '{.securityContext.capabilities.drop}/{.securityContext.capabilities.add}'
  check "baseline: run as non-root (require-run-as-non-root)" \
    every_container_is true '{.securityContext.runAsNonRoot}'
  check "baseline: no host ports (disallow-host-ports)" \
    every_container_is "" '{.ports[*].hostPort}'

  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml" \
    --set ingress.gateways.https.infrastructure.autoscaling.enabled=true \
    --set ingress.gateways.https.infrastructure.autoscaling.minReplicas=2 \
    --set ingress.gateways.https.infrastructure.autoscaling.maxReplicas=3
  check "autoscaling: a HorizontalPodAutoscaler with minReplicas 2 and maxReplicas 3" \
    retry field_is "2 3" hpa/https-istio '{.spec.minReplicas} {.spec.maxReplicas}'
}
