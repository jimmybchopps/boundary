#!/usr/bin/env bash
# Helpers for the boundary e2e tests. Sourced by run.sh; expects MESH, CLUSTER, ROOT, HERE, the
# tool variables (K3D, KUBECTL, HELM, ISTIOCTL), the image variables, and the pinned downloads
# (GATEWAY_API_CRDS, POSTURE_CHART, POLICY_CRD) to be set.

# ---------------------------------------------------------------------------------------------
# Output

log() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

quiet() { # quiet <command...>: runs it silently; prints its output only if it fails
  local out
  if ! out=$("$@" 2>&1); then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

PASSED=0
FAILED=0
FAILURES=()

record() { # record <PASS|FAIL> <message>
  printf '%s %s\n' "$1" "$2"
  if [[ $1 == PASS ]]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILURES+=("$2")
  fi
}

# check <message> <command...>: records PASS if the command succeeds, FAIL otherwise. For
# checks that aren't connections (a scenario's extra).
check() {
  local message=$1
  shift
  if "$@" >/dev/null 2>&1; then record PASS "$message"; else record FAIL "$message"; fi
}

SKIPPED=()

summary() {
  log "summary: ${PASSED} passed, ${FAILED} failed${SKIPPED[*]:+, scenarios skipped for this mesh: ${SKIPPED[*]}}"
  local f
  for f in "${FAILURES[@]}"; do printf '  FAIL %s\n' "$f"; done
  [[ $FAILED -eq 0 ]]
}

# ---------------------------------------------------------------------------------------------
# Cluster

# A plain k3d cluster: flannel stays, since nothing in these scenarios depends on NetworkPolicy
# enforcement (mTLS is enforced by ztunnel). Traefik is disabled: the gateways are this chart's.
create_cluster() {
  log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE})"
  quiet "$K3D" cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --agents 1 \
    --k3s-arg '--disable=traefik@server:*' \
    --wait
  quiet "$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=120s
}

delete_cluster() {
  "$K3D" cluster delete "$CLUSTER" >/dev/null 2>&1 || true
}

# The Gateway API CRDs (standard channel), a prerequisite of this chart that must exist before
# Istio starts, so istiod picks them up.
install_gateway_api() {
  log "installing the Gateway API CRDs ($(basename "$(dirname "$GATEWAY_API_CRDS")"), standard)"
  quiet "$KUBECTL" apply --server-side -f "$GATEWAY_API_CRDS"
  # The file also holds a ValidatingAdmissionPolicy and its binding, which have no Established
  # condition, so wait on the CRDs it defines by name. (bundle-version is an annotation, not a
  # label, so it can't be used as a selector.)
  local crds
  crds=$("$KUBECTL" get -f "$GATEWAY_API_CRDS" -o name | grep '^customresourcedefinition')
  [[ -n $crds ]] || die "no CRDs found in $GATEWAY_API_CRDS"
  # shellcheck disable=SC2086 # one name per word
  quiet "$KUBECTL" wait --for=condition=Established $crds --timeout=60s
  info "Gateway API CRDs established ($(wc -w <<<"$crds") CRDs)"
}

# Istio ambient: istiod and ztunnel in istio-system, istio-cni in kube-system. platform=k3d
# points istio-cni at k3s's CNI directories.
install_istio() {
  log "installing Istio ${ISTIO_VERSION} (ambient, platform k3d)"
  quiet "$HELM" repo add istio https://blob.istio.io/istio-release/charts --force-update
  istio_chart istio-system istio-base base    --create-namespace
  istio_chart istio-system istiod     istiod  --set profile=ambient
  istio_chart kube-system  istio-cni  cni     --set profile=ambient
  istio_chart istio-system ztunnel    ztunnel
  quiet "$KUBECTL" -n kube-system rollout status daemonset/istio-cni-node --timeout=300s
  quiet "$KUBECTL" -n istio-system rollout status daemonset/ztunnel --timeout=300s
  info "istio-cni and ztunnel are ready on every node"
}

istio_chart() { # istio_chart <namespace> <release> <chart> [helm args...]
  local ns=$1 release=$2 chart=$3
  shift 3
  quiet "$HELM" install "$release" "istio/$chart" -n "$ns" --version "$ISTIO_VERSION" \
    --set global.platform=k3d --wait "$@"
  info "${release} installed in ${ns}"
}

# The gateway namespaces, as this chart expects them (CLAUDE.md, prerequisites): created and
# enrolled in the mesh, each with its posture release installed first. Until posture has the
# gateway profiles, that release renders only posture-exceptions (values/exceptions-only.yaml),
# whose CRD comes from the pinned policy release. They stay for the whole run.
GATEWAY_NAMESPACES=(ingress-gateway egress-gateway)

gateway_namespaces() {
  log "creating the gateway namespaces, each with posture $(basename "$POSTURE_CHART" .tgz)"
  quiet "$KUBECTL" apply -f "$POLICY_CRD"
  quiet "$KUBECTL" wait --for=condition=Established crd/policyexceptions.policy.posture.dev --timeout=60s
  local ns
  for ns in "${GATEWAY_NAMESPACES[@]}"; do
    "$KUBECTL" create namespace "$ns" >/dev/null
    "$KUBECTL" label namespace "$ns" istio.io/dataplane-mode=ambient >/dev/null
    quiet "$HELM" install posture "$POSTURE_CHART" -n "$ns" \
      -f "$HERE/values/exceptions-only.yaml" --wait
    info "${ns}: in the mesh, posture installed"
  done
}

# ---------------------------------------------------------------------------------------------
# Namespaces and workloads

NAMESPACES=()

# namespace <name>: created fresh; in the ambient mesh when MESH=istio, unless MESHED=0 (a
# namespace outside the mesh, whose clients send plaintext), e.g. MESHED=0 namespace plain
namespace() {
  local ns=$1
  "$KUBECTL" create namespace "$ns" >/dev/null
  if [[ $MESH == istio && ${MESHED:-1} != 0 ]]; then
    "$KUBECTL" label namespace "$ns" istio.io/dataplane-mode=ambient >/dev/null
  fi
  NAMESPACES+=("$ns")
}

# workload <namespace> <name> <port>...
# A Deployment whose pods are labeled app.kubernetes.io/name=<name> and run as the
# ServiceAccount <name>, with a server container (agnhost porter, HTTP on every port, readiness
# probe on the first) and a client container (curl), plus a Service <name>.<namespace> on the
# same ports. It meets the policy chart's baseline (non-root, RuntimeDefault seccomp, no
# privilege escalation, every capability dropped), so it's admitted under it too.
#
# For an impostor, override with environment variables:
#   LABEL=<name>  pods carry app.kubernetes.io/name=<LABEL> instead; no Service is created
#                 (it would select the real workload's pods too)
#   SA=<name>     pods run as this ServiceAccount instead
#
# The Deployment selects its pods by e2e.boundary.posture.dev/deployment=<name>, not by the name
# label, so an impostor's pods never count as the real workload's.
workload() {
  local ns=$1 name=$2
  shift 2
  local label=${LABEL:-$name} sa=${SA:-$name}
  local env="" svc_ports="" port
  for port in "$@"; do
    env+="
            - { name: SERVE_PORT_${port}, value: ${name}-${port} }"
    svc_ports+="
    - { name: p${port}, port: ${port}, targetPort: ${port} }"
  done
  local service=""
  if [[ -z ${LABEL:-} ]]; then
    service="---
apiVersion: v1
kind: Service
metadata: { name: ${name}, namespace: ${ns} }
spec:
  selector: { app.kubernetes.io/name: ${name} }
  ports: ${svc_ports}"
  fi
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: ${sa}, namespace: ${ns} }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${name}, namespace: ${ns} }
spec:
  replicas: 1
  selector: { matchLabels: { e2e.boundary.posture.dev/deployment: ${name} } }
  template:
    metadata:
      labels: { app.kubernetes.io/name: ${label}, e2e.boundary.posture.dev/deployment: ${name} }
    spec:
      serviceAccountName: ${sa}
      terminationGracePeriodSeconds: 1
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: server
          image: ${AGNHOST_IMAGE}
          args: [porter]
          env: ${env}
          readinessProbe:
            tcpSocket: { port: $1 }
            periodSeconds: 2
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
        - name: client
          image: ${CURL_IMAGE}
          command: [sleep, infinity]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
${service}
EOF
}

# has_deployments <namespace>: whether it has any (a scenario may use bare Pods only).
has_deployments() {
  [[ -n $("$KUBECTL" -n "$1" get deployment -o name) ]]
}

wait_ready() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    has_deployments "$ns" || continue
    "$KUBECTL" -n "$ns" wait --for=condition=Available deployment --all --timeout=180s >/dev/null
  done
}

# install_boundary <example file under examples/> [helm args...]
# This chart as release "boundary" in istio-system (it creates objects in several namespaces,
# each set explicitly). Extra arguments go to helm after the example, e.g. --set mtls.mode=...
install_boundary() {
  local example=$1
  shift
  quiet "$HELM" upgrade --install boundary "$ROOT/charts/boundary" -n istio-system \
    --reset-values -f "$ROOT/examples/${example}" --set "mesh=${MESH}" "$@" --wait
  info "boundary installed (examples/${example}${*:+ $*})"
}

# uninstall_boundary: its objects are mesh-wide, so every scenario that installs it removes it
# in its teardown, before the next scenario's baseline.
uninstall_boundary() {
  "$HELM" uninstall boundary -n istio-system --wait >/dev/null 2>&1 || true
  info "boundary uninstalled"
}

# restart_workloads: replaces every pod in the scenario's namespaces and waits until only the
# new ones are left. Used under Istio ambient after the chart is installed: ztunnel pools the
# HBONE connections the baseline checks opened and sends later requests over them, so without
# this a deny could still connect. New pods have new addresses and no pooled connections.
restart_workloads() {
  local ns d
  for ns in "${NAMESPACES[@]}"; do
    has_deployments "$ns" || continue
    quiet "$KUBECTL" -n "$ns" rollout restart deployment
  done
  for ns in "${NAMESPACES[@]}"; do
    for d in $("$KUBECTL" -n "$ns" get deployment -o name); do
      quiet "$KUBECTL" -n "$ns" rollout status "$d" --timeout=180s
    done
  done
  # kubectl exec deploy/<name> may pick a pod that's still terminating; wait until they're gone.
  local _attempt terminating
  for _attempt in $(seq 1 30); do
    terminating=""
    for ns in "${NAMESPACES[@]}"; do
      terminating+=$("$KUBECTL" -n "$ns" get pods -o jsonpath='{.items[*].metadata.deletionTimestamp}')
    done
    [[ -z $terminating ]] && break
    sleep 2
  done
  [[ -z $terminating ]] || die "old pods are still terminating after the restart"
  info "workloads restarted (drops connections ztunnel pooled during the baseline)"
}

cleanup_namespaces() {
  local ns
  for ns in "${NAMESPACES[@]}"; do
    "$KUBECTL" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
  done
  for ns in "${NAMESPACES[@]}"; do
    "$KUBECTL" wait --for=delete "namespace/$ns" --timeout=120s >/dev/null 2>&1 || true
  done
  NAMESPACES=()
}

# ---------------------------------------------------------------------------------------------
# Checks
#
# Scenarios declare checks with `expect allow|deny <namespace>/<workload> <host>:<port>`.
# run_checks then runs them: every allow first (retried while policies propagate), then every
# deny (retried until the connection fails, so a policy that's still being programmed doesn't
# count as a pass). A deny is "no HTTP response": under Istio ambient a refused connection can
# be reset by ztunnel instead of timing out.

ALLOWS=()
DENIES=()

expect() { # expect <allow|deny> <ns>/<workload> <host>:<port>
  case $1 in
    allow) ALLOWS+=("$2 $3") ;;
    deny) DENIES+=("$2 $3") ;;
    *) die "expect: unknown expectation $1" ;;
  esac
}

connect() { # connect <ns>/<workload> <host>:<port>; succeeds on an HTTP response
  local ns=${1%%/*} name=${1#*/}
  "$KUBECTL" -n "$ns" exec "deploy/${name}" -c client -- \
    curl -sS -o /dev/null -m 3 "http://$2/" >/dev/null 2>&1
}

retry_until() { # retry_until <want: up|down> <from> <to>
  local want=$1 _attempt
  for _attempt in 1 2 3 4 5 6; do
    if connect "$2" "$3"; then
      [[ $want == up ]] && return 0
    else
      [[ $want == down ]] && return 0
    fi
    sleep 2
  done
  return 1
}

# run_checks <phase>: "baseline" (the chart isn't installed: everything must connect) or
# "chart"
run_checks() {
  local phase=$1 check from to
  for check in "${ALLOWS[@]}"; do
    read -r from to <<<"$check"
    if retry_until up "$from" "$to"; then
      record PASS "[$phase] allow $from -> $to"
    else
      record FAIL "[$phase] allow $from -> $to"
    fi
  done
  for check in "${DENIES[@]}"; do
    read -r from to <<<"$check"
    if [[ $phase == baseline ]]; then
      if retry_until up "$from" "$to"; then
        record PASS "[baseline] reachable before boundary: $from -> $to"
      else
        record FAIL "[baseline] reachable before boundary: $from -> $to (the deny check below would prove nothing)"
      fi
    elif retry_until down "$from" "$to"; then
      record PASS "[$phase] deny $from -> $to"
    else
      record FAIL "[$phase] deny $from -> $to"
    fi
  done
}

# run_scenario <name>: sources scenarios/<name>.sh, which defines setup, install, and checks
# (and optionally extra, for checks that aren't connections, and teardown, which undoes
# anything outside the scenario's namespaces, such as this chart's mesh-wide objects; it runs
# before the namespaces are deleted).
run_scenario() {
  local name=$1 before=$FAILED
  log "scenario ${name} (mesh: ${MESH})"
  unset -f setup install checks extra teardown
  unset SCENARIO_MESHES
  [[ -f "${HERE}/scenarios/${name}.sh" ]] || die "no scenario ${name} (test/e2e/scenarios/${name}.sh)"
  # shellcheck source=/dev/null
  source "${HERE}/scenarios/${name}.sh"
  # A scenario may set SCENARIO_MESHES=(istio ...) to run only under those meshes.
  if [[ -n ${SCENARIO_MESHES+x} && " ${SCENARIO_MESHES[*]} " != *" ${MESH} "* ]]; then
    info "skipped: needs MESH=${SCENARIO_MESHES[*]}"
    SKIPPED+=("$name")
    return 0
  fi
  ALLOWS=()
  DENIES=()
  setup
  wait_ready
  checks
  run_checks baseline
  install
  if [[ $MESH == istio ]]; then restart_workloads; fi
  run_checks chart
  if declare -F extra >/dev/null; then extra; fi
  if [[ $FAILED -gt $before ]]; then
    dump_state
    if [[ ${E2E_KEEP:-0} == 1 ]]; then
      # Keep this scenario's namespaces and the chart to inspect; later scenarios may reuse
      # their names, so stop.
      KEPT_SCENARIO=$name
      info "keeping namespaces ${NAMESPACES[*]} and the boundary release (E2E_KEEP=1); skipping the remaining scenarios"
      return 0
    fi
  fi
  if declare -F teardown >/dev/null; then teardown; fi
  cleanup_namespaces
}

# shellcheck disable=SC2034 # read by run.sh
KEPT_SCENARIO=""

# dump_state: a short overview after a failed scenario. For details, rerun with E2E_KEEP=1 and
# inspect what it keeps.
dump_state() {
  local ns
  printf '\n--- mesh-wide (istio-system)\n'
  "$KUBECTL" -n istio-system get peerauthentications,authorizationpolicies 2>&1 || true
  for ns in "${NAMESPACES[@]}"; do
    printf '\n--- namespace %s\n' "$ns"
    "$KUBECTL" -n "$ns" get pods -o wide 2>&1 || true
    if [[ $MESH == istio && -n ${ISTIOCTL:-} ]]; then
      "$ISTIOCTL" ztunnel-config workloads --workload-namespace "$ns" 2>&1 || true
    fi
  done
  if [[ ${E2E_KEEP:-0} != 1 ]]; then
    printf '\n(rerun with E2E_KEEP=1 E2E_ARGS=<scenario> to keep these namespaces for inspection)\n'
  fi
}
