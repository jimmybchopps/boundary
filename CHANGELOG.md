# Changelog

Newest first, one `## X.Y.Z` section per release. A version's section stays marked
`(unreleased)` until the release commit; the release workflow refuses a tag whose section
still is, or whose version doesn't match `charts/boundary/Chart.yaml`.

## 0.1.1 (unreleased)

The gateway and waypoint pods now pass the `policy` chart's two remaining default-on policies
without a `posture` exception.

- **`automountServiceAccountToken: false`** on every ingress gateway and egress waypoint pod,
  through the infrastructure ConfigMap (`disallow-automount-service-account-token`). The proxy
  doesn't use the API token: it authenticates to istiod with the projected `istio-token`.
- **A liveness probe on `istio-proxy`** (`require-probes`): `/healthz/ready` on 15021, the
  endpoint of Istio's own startup and readiness probes, every 15 seconds, restarting after 8
  failures.
- **Waypoints get their own ServiceAccount**, `<gateway>-waypoint`, through the Gateway's
  `gateway.istio.io/service-account` annotation (`disallow-default-service-account`). Istio
  names a waypoint's ServiceAccount after the Gateway, so the `default` waypoint ran as the
  namespace's `default` ServiceAccount and its pods were refused. On upgrade the waypoint's
  identity changes from `sa/default` to `sa/default-waypoint`; nothing in this chart or
  `posture` refers to it.
- The integration run enforces `disallow-default-service-account`,
  `disallow-rbac-escalation-verbs`, `disallow-secrets-in-env`, and
  `disallow-shared-process-namespace` as well, and checks the gateway pods for the two fixes
  above (enforced once the run pins `posture` 0.3.0). Its workloads meet every default-on
  policy.

## 0.1.0

First release: security at the edge of the cluster for **Istio in ambient mode**. The chart
creates resources in the mesh that's already running and never installs the mesh.

- **Mesh-wide:** PeerAuthentication `mtls-strict` (default) or `mtls-permissive` in
  `istio.rootNamespace`, or nothing with `mtls.mode: inherit`; an optional allow-nothing
  `deny-all` (`meshDefaultDeny`); access logs for every gateway and waypoint (`accessLogs`,
  Istio's `envoy` provider).
- **Ingress gateways**, each its own Gateway, Service, and address in `ingress.namespace`:
  - `https` (on by default): TLS terminated with certificates from Secrets in the ingress
    namespace, and an HTTP listener that answers every request with a 301 to HTTPS;
  - `tls-passthrough` (off): TLS routed by SNI to workloads that terminate it themselves;
  - `tcp` (off): one listener per TCP service, which only that service's namespace may use.

  Namespaces attach routes with the label `ingress.boundary.posture.dev/<gateway>: "true"`.
  TLS versions and TLS 1.2 cipher suites are chart-wide, with per-listener overrides, applied
  with one EnvoyFilter per gateway.
- **Egress gateways:** an Istio waypoint per `egress.gateways` entry, exactly one of them the
  default. Its `allowedHosts` are the cluster-wide limit on where traffic through it may go,
  enforced at the waypoint by destination: TLS by server name, HTTP by Host, TCP by address,
  each with its ports, plus an allow-nothing policy so a waypoint with no entries is closed.
  Workloads ask for hosts through their own `posture` release; this chart creates no
  ServiceEntries. `exitNodes` pins a waypoint to nodes.
- **Infrastructure** for every gateway and waypoint through the Gateway's `parametersRef`:
  replicas, autoscaling, a disruption budget, topology spread, node selector, tolerations,
  and resources.
- **Compliance:** the generated gateway and waypoint pods pass the `policy` chart's baseline
  (seccomp `RuntimeDefault` set through the infrastructure parameters) and carry
  `app.kubernetes.io/name: <gateway>` and `app.kubernetes.io/component: ingress-gateway` or
  `egress-waypoint`. With `posture`'s gateway profiles, they're admitted under the policy
  chart's defaults enforced with one exception (`disallow-mesh-opt-out`). The README's
  "Running under the policy chart" lists what a site sets.
- **Values:** maps keyed by name with `enabled` on every gateway, listener, and allowed host;
  checked by a JSON schema and the chart's model. A setting that can't be applied fails the
  install with its values path and the reason; every object carries
  `boundary.posture.dev/rule`, the values path it came from.
- **Not yet supported, so the install fails:** `mesh` `linkerd`, `cilium`, or `none`, and
  `ingress.implementation` `envoy-gateway` or `cilium` (docs/PLAN.md, phases 5 to 8).

Requires and tested with: the Gateway API CRDs v1.6.0 or later (standard channel), Istio 1.32
in ambient mode, `posture` 0.2.0 or later in the gateway namespaces, `policy` 0.2.1 or later
(when its `restrict-route-hostnames` is on), and Helm 3.14 or later, including Helm 4.
