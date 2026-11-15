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
# k3s's packaged Gateway API CRDs (the gateway-api-crd add-on) are disabled too: the harness
# installs the pinned ones (install_gateway_api), and k3s's would race them.
create_cluster() {
  log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE})"
  quiet "$K3D" cluster create "$CLUSTER" \
    --image "$K3S_IMAGE" \
    --agents 1 \
    --k3s-arg '--disable=traefik@server:*' \
    --k3s-arg '--disable=gateway-api-crd@server:*' \
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
  istio_chart kube-system  istio-cni  cni     --set profile=ambient --set global.platform=k3s
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

# The namespaces this chart's ingress gateways and egress waypoints run in
# (ingress.namespace, egress.namespace).
INGRESS_NAMESPACE=ingress-gateway
EGRESS_NAMESPACE=egress-gateway

# install_boundary <example file under examples/> [helm args...]
# This chart as release "boundary" in istio-system (it creates objects in several namespaces,
# each set explicitly). Extra arguments go to helm after the example, e.g. --set mtls.mode=...
# or -f "$HERE/values/ingress.yaml". Waits until every ingress gateway and egress waypoint is
# programmed and its Deployment is available.
install_boundary() {
  local example=$1
  shift
  quiet "$HELM" upgrade --install boundary "$ROOT/charts/boundary" -n istio-system \
    --reset-values -f "$ROOT/examples/${example}" --set "mesh=${MESH}" "$@" --wait
  wait_gateways
  info "boundary installed (examples/${example}${*:+ $*})"
}

# wait_gateways: every Gateway in the ingress and egress namespaces is Programmed and the
# Deployment Istio generates for it is available. The Deployment is found by its gateway-name
# label: it's <gateway>-istio for an ingress gateway, but plain <gateway> for a waypoint.
wait_gateways() {
  local ns gateway deployment
  for ns in "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    for gateway in $("$KUBECTL" -n "$ns" get gateways -o jsonpath='{.items[*].metadata.name}'); do
      quiet "$KUBECTL" -n "$ns" wait --for=condition=Programmed "gateway/$gateway" --timeout=180s ||
        { "$KUBECTL" -n "$ns" get "gateway/$gateway" -o yaml >&2; return 1; }
      retry gateway_deployment "$ns" "$gateway" ||
        die "Istio generated no Deployment for gateway ${ns}/${gateway}"
      deployment=$(gateway_deployment "$ns" "$gateway")
      quiet "$KUBECTL" -n "$ns" rollout status "$deployment" --timeout=180s
    done
  done
}

# gateway_deployment <namespace> <gateway>: prints the Deployment Istio generated for it
# (deployment.apps/<name>); fails if there's none yet.
gateway_deployment() {
  local d
  d=$("$KUBECTL" -n "$1" get deployment -l "gateway.networking.k8s.io/gateway-name=$2" -o name 2>/dev/null)
  [[ -n $d ]] && printf '%s\n' "$d"
}

# uninstall_boundary: its objects are mesh-wide, so every scenario that installs it removes it
# in its teardown, before the next scenario's baseline. Waits until the Deployments Istio
# generated for its gateways are gone, so the next scenario's gateways start fresh.
uninstall_boundary() {
  local ns
  "$HELM" uninstall boundary -n istio-system --wait >/dev/null 2>&1 || true
  for ns in "$INGRESS_NAMESPACE" "$EGRESS_NAMESPACE"; do
    "$KUBECTL" -n "$ns" wait --for=delete deployment \
      -l gateway.networking.k8s.io/gateway-name --timeout=120s >/dev/null 2>&1 || true
  done
  info "boundary uninstalled"
}

# retry <command...>: runs it until it succeeds, for up to about 30 seconds.
retry() {
  local _attempt
  for _attempt in $(seq 1 15); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Certificates (ingress scenarios)
#
# A CA and certificates signed by it, in CERTS (a directory run.sh creates and removes).

# make_ca: the run's CA, once (CERTS/ca.crt, CERTS/ca.key).
make_ca() {
  [[ -f $CERTS/ca.crt ]] && return 0
  quiet openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=boundary-e2e-ca" \
    -keyout "$CERTS/ca.key" -out "$CERTS/ca.crt"
}

# make_cert <name> <hostname>...: CERTS/<name>.crt and .key for those hostnames, signed by the
# CA, with a fresh serial. ORG=<token> puts that token in the subject (O=<token>), so a check
# can tell two certificates for the same hostnames apart, e.g. ORG=rotated make_cert apps ...
make_cert() {
  local name=$1
  shift
  make_ca
  local san="" host
  for host in "$@"; do san+="${san:+,}DNS:${host}"; done
  printf 'subjectAltName=%s\n' "$san" >"$CERTS/$name.ext"
  quiet openssl req -newkey rsa:2048 -nodes -subj "/CN=$1/O=${ORG:-boundary-e2e}" \
    -keyout "$CERTS/$name.key" -out "$CERTS/$name.csr"
  quiet openssl x509 -req -in "$CERTS/$name.csr" -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" \
    -set_serial "0x$(openssl rand -hex 8)" -days 2 -extfile "$CERTS/$name.ext" -out "$CERTS/$name.crt"
}

# tls_secret <namespace> <secret> <cert name>: a kubernetes.io/tls Secret from CERTS/<cert>,
# created or replaced.
tls_secret() {
  "$KUBECTL" -n "$1" create secret tls "$2" --cert="$CERTS/$3.crt" --key="$CERTS/$3.key" \
    --dry-run=client -o yaml | quiet "$KUBECTL" apply -f -
}

# copy_to <ns>/<workload> <local file> <path>: writes the file into the workload's client
# container (e.g. the CA, for curl --cacert).
copy_to() {
  local ns=${1%%/*} name=${1#*/}
  "$KUBECTL" -n "$ns" exec -i "deploy/${name}" -c client -- sh -c "cat > '$3'" <"$2"
}

# ---------------------------------------------------------------------------------------------
# Ingress (gateways and routes)

# gateway_curl <ns>/<workload> <gateway> <host> <port> <curl args...>
# curl from the workload's client container to <gateway>'s Service, with <host> as the SNI and
# Host (--connect-to), e.g.
#   gateway_curl client/x https api.apps.e2e.test 443 --cacert /tmp/ca.crt https://api.apps.e2e.test/
gateway_curl() {
  local ns=${1%%/*} name=${1#*/} gateway=$2 host=$3 port=$4
  shift 4
  "$KUBECTL" -n "$ns" exec "deploy/${name}" -c client -- curl -sS -m 5 \
    --connect-to "${host}:${port}:${gateway}-istio.${INGRESS_NAMESPACE}.svc.cluster.local:${port}" "$@"
}

# status_is <want> <gateway_curl args...>: the response's status code is <want>.
status_is() {
  local want=$1 got
  shift
  got=$(gateway_curl "$@" -o /dev/null -w '%{http_code}' 2>/dev/null) || true
  [[ $got == "$want" ]]
}

# redirects_to <location> <gateway_curl args...>: the response is a 301 to <location>.
redirects_to() {
  local want=$1 got
  shift
  got=$(gateway_curl "$@" -o /dev/null -w '%{http_code} %{redirect_url}' 2>/dev/null) || true
  [[ $got == "301 $want" ]]
}

# connects <gateway_curl args...>: the request gets any HTTP response.
connects() {
  gateway_curl "$@" -o /dev/null >/dev/null 2>&1
}

# refused <gateway_curl args...>: the request gets no HTTP response (e.g. the TLS handshake
# fails).
refused() {
  ! connects "$@"
}

# subject_has <token> <gateway_curl args...>: the subject of the certificate the server
# presented (curl -v) contains token.
subject_has() {
  local token=$1 subject
  shift
  subject=$(gateway_curl "$@" -v -o /dev/null 2>&1 | grep -i 'subject:' | head -n 1) || true
  [[ $subject == *"$token"* ]]
}

# route <kind> <namespace> <name> <gateway> <section or ""> <hostnames ("" for none)> <service> <port>
# A Gateway API route (HTTPRoute, TLSRoute, TCPRoute) in <namespace>, attached to <gateway> in
# the ingress namespace (listener <section>, or every listener when empty), sending everything
# to <service>:<port>.
route() {
  local kind=$1 ns=$2 name=$3 gateway=$4 section=$5 hostnames=$6 service=$7 port=$8 h
  local hosts="" sectionLine=""
  for h in $hostnames; do hosts+="
    - ${h}"; done
  if [[ -n $section ]]; then sectionLine="sectionName: ${section}"; fi
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: ${kind}
metadata: { name: ${name}, namespace: ${ns} }
spec:
  parentRefs:
    - name: ${gateway}
      namespace: ${INGRESS_NAMESPACE}
      ${sectionLine}
  ${hosts:+hostnames: ${hosts}}
  rules:
    - backendRefs:
        - { name: ${service}, port: ${port} }
EOF
}

# route_accepted <kind> <ns>/<name> <True|False> [reason]: the route's Accepted condition (on
# its first parent) has that status, and that reason when given.
route_accepted() {
  local kind=$1 ns=${2%%/*} name=${2#*/} want=$3 reason=${4:-} got
  got=$("$KUBECTL" -n "$ns" get "$kind" "$name" \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}/{.status.parents[0].conditions[?(@.type=="Accepted")].reason}')
  [[ ${got%%/*} == "$want" && ( -z $reason || ${got#*/} == "$reason" ) ]]
}

# tls_workload <namespace> <name> <port> <secret>: like workload, but the server terminates TLS
# itself (agnhost netexec over HTTPS on <port>), with the certificate in Secret <secret>
# (mounted from a secret volume). For TLS passthrough.
tls_workload() {
  local ns=$1 name=$2 port=$3 secret=$4
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: { name: ${name}, namespace: ${ns} }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${name}, namespace: ${ns} }
spec:
  replicas: 1
  selector: { matchLabels: { e2e.boundary.posture.dev/deployment: ${name} } }
  template:
    metadata:
      labels: { app.kubernetes.io/name: ${name}, e2e.boundary.posture.dev/deployment: ${name} }
    spec:
      serviceAccountName: ${name}
      terminationGracePeriodSeconds: 1
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile: { type: RuntimeDefault }
      volumes:
        - name: tls
          secret: { secretName: ${secret} }
      containers:
        - name: server
          image: ${AGNHOST_IMAGE}
          args:
            - netexec
            - --http-port=${port}
            - --udp-port=-1
            - --tls-cert-file=/tls/tls.crt
            - --tls-private-key-file=/tls/tls.key
          volumeMounts:
            - { name: tls, mountPath: /tls, readOnly: true }
          readinessProbe:
            tcpSocket: { port: ${port} }
            periodSeconds: 2
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
---
apiVersion: v1
kind: Service
metadata: { name: ${name}, namespace: ${ns} }
spec:
  selector: { app.kubernetes.io/name: ${name} }
  ports:
    - { name: tls, port: ${port}, targetPort: ${port} }
EOF
}

# gateway_pods <gateway>: its pods' names and UIDs with their restart counts, one per line, for
# comparing before and after a change.
gateway_pods() {
  "$KUBECTL" -n "$INGRESS_NAMESPACE" get pods -l "gateway.networking.k8s.io/gateway-name=$1" \
    -o jsonpath='{range .items[*]}{.metadata.uid} {.status.containerStatuses[0].restartCount}{"\n"}{end}' | sort
}

# gateway_logs_have <namespace> <gateway> <text>: one of the gateway's (or waypoint's) pods
# logged a line containing text.
# Reads each pod's whole log by name: with a selector (-l), kubectl logs shows only the last 10
# lines per pod, even with --tail=-1. And no pipe into grep -q, which under pipefail can fail
# with SIGPIPE after a match.
gateway_logs_have() {
  local ns=$1 pod logs
  for pod in $("$KUBECTL" -n "$ns" get pods \
    -l "gateway.networking.k8s.io/gateway-name=$2" -o name 2>/dev/null); do
    logs=$("$KUBECTL" -n "$ns" logs "$pod" -c istio-proxy 2>/dev/null) || continue
    [[ $logs == *"$3"* ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Gateway and waypoint pods (infrastructure scenarios)

# gateway_field_is <namespace> <want> <kubectl get args...> <jsonpath>: that field of the object
# is <want>, e.g. gateway_field_is egress-gateway 1 pdb/default '{.spec.minAvailable}'.
gateway_field_is() {
  local ns=$1 want=$2 got
  shift 2
  got=$("$KUBECTL" -n "$ns" get "${@:1:$#-1}" -o "jsonpath=${!#}" 2>/dev/null) || return 1
  [[ $got == "$want" ]]
}

# pods_all_equal <namespace> <gateway> <want> <jsonpath template>: the template, printed once
# per line over the gateway's pods, gives <want> on every line, and there is at least one pod.
pods_all_equal() {
  local ns=$1 selector="gateway.networking.k8s.io/gateway-name=$2" want=$3 lines line
  [[ -n $("$KUBECTL" -n "$ns" get pods -l "$selector" -o name) ]] || return 1
  lines=$("$KUBECTL" -n "$ns" get pods -l "$selector" -o "jsonpath=$4") || return 1
  while IFS= read -r line; do [[ $line == "$want" ]] || return 1; done <<<"$lines"
}

# every_pod_is <namespace> <gateway> <want> <field jsonpath>: that field of each of its pods.
every_pod_is() {
  pods_all_equal "$1" "$2" "$3" "{range .items[*]}$4{\"\\n\"}{end}"
}

# every_container_is <namespace> <gateway> <want> <field jsonpath>: that field of each container
# of its pods.
every_container_is() {
  pods_all_equal "$1" "$2" "$3" "{range .items[*]}{range .spec.containers[*]}$4{\"\\n\"}{end}{end}"
}

# only_safe_sysctls <namespace> <gateway>: its pods set no sysctls outside Kubernetes' safe set
# (the policy chart's restrict-sysctls).
only_safe_sysctls() {
  local names name
  names=$("$KUBECTL" -n "$1" get pods -l "gateway.networking.k8s.io/gateway-name=$2" \
    -o jsonpath='{range .items[*]}{.spec.securityContext.sysctls[*].name}{" "}{end}') || return 1
  for name in $names; do
    case $name in
      kernel.shm_rmid_forced | net.ipv4.ip_local_port_range | net.ipv4.ip_unprivileged_port_start | \
        net.ipv4.tcp_syncookies | net.ipv4.ping_group_range | net.ipv4.ip_local_reserved_ports | \
        net.ipv4.tcp_keepalive_time | net.ipv4.tcp_fin_timeout | net.ipv4.tcp_keepalive_intvl | \
        net.ipv4.tcp_keepalive_probes) ;;
      *) return 1 ;;
    esac
  done
}

# baseline_checks <namespace> <gateway>: the policy chart's baked-in baseline, as the gateway's
# (or waypoint's) generated pods run (README, "Gateway pod compliance").
baseline_checks() {
  local ns=$1 gw=$2
  check "baseline: pod seccompProfile RuntimeDefault (restrict-seccomp, from the ConfigMap)" \
    every_pod_is "$ns" "$gw" RuntimeDefault '{.spec.securityContext.seccompProfile.type}'
  check "baseline: no host namespaces (disallow-host-namespaces)" \
    every_pod_is "$ns" "$gw" "//" '{.spec.hostNetwork}/{.spec.hostPID}/{.spec.hostIPC}'
  check "baseline: no hostPath volumes (disallow-host-path)" \
    every_pod_is "$ns" "$gw" "" '{.spec.volumes[*].hostPath}'
  check "baseline: only safe sysctls (restrict-sysctls)" \
    only_safe_sysctls "$ns" "$gw"
  check "baseline: no privilege escalation (disallow-privilege-escalation)" \
    every_container_is "$ns" "$gw" false '{.securityContext.allowPrivilegeEscalation}'
  check "baseline: not privileged (disallow-privileged-containers)" \
    every_container_is "$ns" "$gw" false '{.securityContext.privileged}'
  check "baseline: drop ALL, add nothing (require-drop-all-capabilities)" \
    every_container_is "$ns" "$gw" '["ALL"]/' '{.securityContext.capabilities.drop}/{.securityContext.capabilities.add}'
  check "baseline: run as non-root (require-run-as-non-root)" \
    every_container_is "$ns" "$gw" true '{.securityContext.runAsNonRoot}'
  check "baseline: no host ports (disallow-host-ports)" \
    every_container_is "$ns" "$gw" "" '{.ports[*].hostPort}'
}

# ---------------------------------------------------------------------------------------------
# External hosts (egress scenarios)
#
# Containers on the k3d Docker network: outside the cluster, on private addresses, started once
# per run (run.sh). Names under e2e.test resolve to them through CoreDNS (external_dns).
#   EXT_A, EXT_B  agnhost porter: HTTP on 80 and 8080
#   EXT_TLS       agnhost netexec: HTTPS on 443, with a certificate for *.e2e.test from the
#                 run's CA (clients use -k: the checks are about the server name, not trust)

start_external() {
  log "starting the external hosts"
  stop_external
  local name
  for name in ext-a ext-b; do
    quiet docker run -d --name "${CLUSTER}-${name}" --network "k3d-${CLUSTER}" \
      -e SERVE_PORT_80="${name}-80" -e SERVE_PORT_8080="${name}-8080" "$AGNHOST_IMAGE" porter
  done
  make_cert external "*.e2e.test"
  chmod 644 "$CERTS/external.key"
  quiet docker run -d --name "${CLUSTER}-ext-tls" --network "k3d-${CLUSTER}" \
    -v "$CERTS:/certs:ro" "$AGNHOST_IMAGE" netexec --http-port=443 --udp-port=-1 \
    --tls-cert-file=/certs/external.crt --tls-private-key-file=/certs/external.key
  EXT_A=$(container_ip ext-a)
  EXT_B=$(container_ip ext-b)
  EXT_TLS=$(container_ip ext-tls)
  [[ -n $EXT_A && -n $EXT_B && -n $EXT_TLS ]] || die "an external host has no IP address"
  export EXT_A EXT_B EXT_TLS
  info "ext-a ${EXT_A}, ext-b ${EXT_B}, ext-tls ${EXT_TLS}"
  external_dns
}

stop_external() {
  local name
  for name in ext-a ext-b ext-tls; do
    docker rm -f "${CLUSTER}-${name}" >/dev/null 2>&1 || true
  done
}

container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CLUSTER}-$1"
}

# external_dns: a CoreDNS server block for e2e.test (k3s imports coredns-custom's *.server
# keys), mapping the scenarios' host names to the external hosts. *-http on ext-a, *-tls on
# ext-tls.
external_dns() {
  local h hosts=""
  for h in allowed-http denied-http second-http; do hosts+="
          ${EXT_A} ${h}.e2e.test"; done
  for h in allowed-tls denied-tls second-tls; do hosts+="
          ${EXT_TLS} ${h}.e2e.test"; done
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata: { name: coredns-custom, namespace: kube-system }
data:
  e2e.server: |
    e2e.test:53 {
        errors
        hosts {${hosts}
        }
    }
EOF
  quiet "$KUBECTL" -n kube-system rollout restart deployment/coredns
  quiet "$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=120s
  info "CoreDNS resolves *.e2e.test to the external hosts"
}

# service_entry <ns> <name> <gateway> <protocol> <ports, comma-separated> hosts|addresses <value>...
# A ServiceEntry routed to egress waypoint <gateway>, shaped as posture renders one for an
# egress.allowedHosts entry: visible only in its namespace, MESH_EXTERNAL, resolution DNS for
# hosts and NONE for addresses (with a placeholder host), ports named <protocol>-<port>.
service_entry() {
  local ns=$1 name=$2 gateway=$3 protocol=$4 ports=$5 kind=$6
  shift 6
  local lower port_lines="" value values="" resolution=DNS hosts addresses=""
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$protocol")
  for port in ${ports//,/ }; do port_lines+="
    - { number: ${port}, name: ${lower}-${port}, protocol: ${protocol} }"; done
  for value in "$@"; do values+="
    - ${value}"; done
  if [[ $kind == hosts ]]; then
    hosts=$values
  else
    resolution=NONE
    hosts="
    - ${name}.${ns}.posture.internal"
    addresses="addresses: ${values}"
  fi
  "$KUBECTL" apply -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    istio.io/use-waypoint: ${gateway}
    istio.io/use-waypoint-namespace: ${EGRESS_NAMESPACE}
spec:
  exportTo: ["."]
  location: MESH_EXTERNAL
  resolution: ${resolution}
  hosts: ${hosts}
  ${addresses}
  ports: ${port_lines}
EOF
}

# service_entry_has_address <ns>/<name>: Istio allocated it an address (status.addresses), so
# ztunnel's DNS answers for its hosts with that address and captures the traffic.
service_entry_has_address() {
  local got
  got=$("$KUBECTL" -n "${1%%/*}" get serviceentry "${1#*/}" -o jsonpath='{.status.addresses[*].value}' 2>/dev/null)
  [[ -n $got ]]
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

expect() { # expect <allow|deny> <ns>/<workload> <host>:<port> | https://<host>:<port>
  case $1 in
    allow) ALLOWS+=("$2 $3") ;;
    deny) DENIES+=("$2 $3") ;;
    *) die "expect: unknown expectation $1" ;;
  esac
}

# connect <ns>/<workload> <target>: succeeds on a successful HTTP response (curl -f, so a
# waypoint's 403 "RBAC: access denied" is a refusal). <target> is host:port (HTTP) or
# https://host:port (TLS, with -k: the server's certificate isn't what's being checked).
connect() {
  local ns=${1%%/*} name=${1#*/} url=$2
  [[ $url == *://* ]] || url="http://${url}"
  "$KUBECTL" -n "$ns" exec "deploy/${name}" -c client -- \
    curl -fsS -k -o /dev/null -m 3 "${url}/" >/dev/null 2>&1
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
  printf '\n--- ingress (%s)\n' "$INGRESS_NAMESPACE"
  "$KUBECTL" -n "$INGRESS_NAMESPACE" get gateways,pods,services,configmaps,envoyfilters,telemetries -o wide 2>&1 || true
  "$KUBECTL" -n "$INGRESS_NAMESPACE" get gateways \
    -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status}({.reason}) {end}| listeners: {range .status.listeners[*]}{.name}={.attachedRoutes} {end}{"\n"}{end}' 2>&1 || true
  "$KUBECTL" -n "$INGRESS_NAMESPACE" get events --sort-by=.lastTimestamp 2>&1 | tail -n 15 || true
  local pod
  for pod in $("$KUBECTL" -n "$INGRESS_NAMESPACE" get pods -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null); do
    printf '\n--- %s (istio-proxy, last 10 lines)\n' "$pod"
    "$KUBECTL" -n "$INGRESS_NAMESPACE" logs "$pod" -c istio-proxy --tail=10 2>&1 || true
  done
  printf '\n--- egress (%s)\n' "$EGRESS_NAMESPACE"
  "$KUBECTL" -n "$EGRESS_NAMESPACE" get gateways,pods,configmaps,authorizationpolicies,telemetries -o wide 2>&1 || true
  "$KUBECTL" -n "$EGRESS_NAMESPACE" get gateways \
    -o jsonpath='{range .items[*]}{.metadata.name}: {range .status.conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}' 2>&1 || true
  for pod in $("$KUBECTL" -n "$EGRESS_NAMESPACE" get pods -l gateway.networking.k8s.io/gateway-name -o name 2>/dev/null); do
    printf '\n--- %s (istio-proxy, last 10 lines)\n' "$pod"
    "$KUBECTL" -n "$EGRESS_NAMESPACE" logs "$pod" -c istio-proxy --tail=10 2>&1 || true
  done
  printf '\n--- service entries\n'
  "$KUBECTL" get serviceentries -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: hosts={.spec.hosts} waypoint={.metadata.labels.istio\.io/use-waypoint} addresses={.status.addresses[*].value}{"\n"}{end}' 2>&1 || true
  printf '\n--- routes\n'
  "$KUBECTL" get httproutes,tlsroutes,tcproutes -A \
    -o jsonpath='{range .items[*]}{.kind} {.metadata.namespace}/{.metadata.name}: {range .status.parents[*].conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}' 2>&1 || true
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
