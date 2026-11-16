# boundary: context for Claude Code

`boundary` is a Helm chart for security at the edge of the cluster: the gateways traffic enters
and leaves through, the cluster-wide limit on where traffic may leave for, and the mesh-wide
defaults that apply to every namespace. It is **mesh-aware, not mesh-installing**: it creates
resources in the mesh that's already running (or, with no mesh, in front of the cluster) and
never installs the mesh itself.

The first phases support **Istio in ambient mode**. Then Envoy Gateway (the ingress for Linkerd
and for clusters with no mesh), Linkerd, and Cilium, each followed by an integration phase.
Multi-cluster is out of scope for now.

The build order is in `docs/PLAN.md`. Work through it phase by phase.

## Prerequisites (never installed by this chart)

- **The mesh**, when there is one, already installed and healthy (for Istio: istiod, istio-cni,
  ztunnel, in ambient mode).
- **The Kubernetes Gateway API CRDs**, v1.6 or later, standard channel (HTTPRoute, TLSRoute, and
  TCPRoute are all standard from v1.6). They must exist before the mesh starts. If they're
  missing, the install fails with Helm's "no matches for kind" error, which the README explains.
- **Envoy Gateway's CRDs** (`gateway.envoyproxy.io`), when `ingress.implementation` is
  `envoy-gateway`. This chart installs Envoy Gateway's controller, never its CRDs.
- **The `ingress-gateway` and `egress-gateway` namespaces**, already created and enrolled in the
  mesh by whoever creates namespaces, each with its `posture` release installed first (profiles
  `istio-ingress` and `istio-egress`). Clusters running the `policy` chart deny everything in a
  namespace without `posture-exceptions`, so `posture` must come before this chart's gateways.
- **TLS certificate Secrets** in the ingress gateway's own namespace, created by the installer
  (or whatever issues certificates). This chart only references them by name.

## Principles (don't break these)

- **Separation of concerns.** This chart never references the `posture` or `policy` charts and
  never creates objects that belong to them. It shares a few **conventions** with them, listed
  below. Changing a convention means changing it in each chart's values; no chart reads another's.
- **Maps for everything a user might override.** Gateways, listeners, and allowed hosts are maps
  keyed by name, each with `enabled` (default true), so a site's values file can change or turn
  off one entry without restating the rest. The only lists are ports, CIDRs, hostnames, and
  certificate names.
- **Values decide, not the cluster.** No `lookup`, no `.Capabilities` checks to choose what to
  render. `helm template` must produce exactly what `helm install` applies.
- **Never silently weaker.** If the selected mesh or ingress implementation can't express
  something the values ask for, call `fail` naming the setting and the reason. Unimplemented
  combinations fail until their phases land.
- **Nothing per application, with one exception.** Adding an application never requires changing
  this chart: namespaces opt in to ingress with a label, and workloads request egress through
  their own `posture`. The exception is the `tcp` gateway: raw TCP has no hostname, so each TCP
  service needs its own listener (port), added here when it's planned.
- **Gateway pods comply without exceptions, with one exception.** Generated gateway and waypoint
  pods are made to pass the `policy` chart's baseline and its default-on policies through each
  Gateway's infrastructure parameters and `spec.infrastructure.labels`, never by relying on
  `posture` exceptions. The one exception is `disallow-mesh-opt-out`: Istio's
  `sidecar.istio.io/inject: "false"` (and the waypoint's `istio.io/dataplane-mode: none`) is what
  makes the gateway the mesh's own proxy, so it stays. The exception lives in posture's
  `istio-ingress` and `istio-egress` profiles, selected by the component label this chart sets.
- **Same-namespace certificates.** Listeners reference Secrets in the gateway's own namespace.
  No cross-namespace references and no ReferenceGrants (a possible later option).
- **Every generated object says why it exists**: annotation `boundary.posture.dev/rule` with the
  values path it came from (`ingress.gateways.https.listeners.https`, ...).

## Values contract

```yaml
mesh: istio                      # istio | linkerd | cilium | none
ingress:
  implementation: ""             # istio | envoy-gateway | cilium; empty = from mesh
                                 # (istio -> istio, cilium -> cilium, linkerd/none -> envoy-gateway)

istio:
  rootNamespace: istio-system    # where mesh-wide resources go

mtls:
  mode: STRICT                   # mesh-wide: STRICT | PERMISSIVE | inherit (render nothing)
meshDefaultDeny: false           # mesh-wide allow-nothing authorization (off by default)
accessLogs:
  enabled: true                  # gateways and waypoints log every connection

tls:                             # defaults for every TLS-terminating listener
  minVersion: TLSv1_2            # TLSv1_2 | TLSv1_3
  maxVersion: TLSv1_3
  cipherSuites: []               # TLS 1.2 only (TLS 1.3 ciphers aren't configurable in Envoy);
                                 # empty = Envoy's defaults

ingress:
  namespace: ingress-gateway
  gateways:
    https:                       # terminates TLS at the gateway; on by default
      enabled: true
      service: { type: LoadBalancer, annotations: {}, loadBalancerIP: "" }
      listeners:
        https:
          port: 443
          protocol: HTTPS
          hostname: "*.apps.example.mil"
          certificates: [apps-tls]          # Secrets in the ingress namespace
          tls: { minVersion: TLSv1_3 }      # optional override of the chart-wide tls
        http:
          port: 80
          protocol: HTTP
          hostname: "*.apps.example.mil"
          redirectToHTTPS: true             # every request gets a 301 to HTTPS
      infrastructure: { ... }               # see below
    tls-passthrough:             # TLS goes through to the workload; off by default
      enabled: false
      service: { type: LoadBalancer }
      listeners:
        tls:
          port: 443
          protocol: TLS                     # passthrough: routed by SNI with TLSRoute
          hostname: "*.apps.example.mil"
    tcp:                         # raw TCP; off by default; one listener per service
      enabled: false
      service: { type: LoadBalancer }
      listeners:
        postgres:
          port: 5432
          protocol: TCP
          namespace: databases              # only this namespace may attach a TCPRoute
  # every gateway also takes:
  #   infrastructure:
  #     replicas: 2
  #     autoscaling: { enabled: false, minReplicas: 2, maxReplicas: 5 }
  #     podDisruptionBudget: { minAvailable: 1 }
  #     topologySpread: true
  #     nodeSelector: {}
  #     tolerations: []
  #     resources: {}

egress:
  namespace: egress-gateway
  gateways:
    default:
      enabled: true
      default: true              # exactly one enabled gateway is the default
      exitNodes: {}              # optional nodeSelector pinning it to exit nodes (off by default)
      allowedHosts:              # the cluster-wide limit for traffic through this gateway
        github:
          hosts: [api.github.com]
          ports: [443]
          protocol: TLS          # TLS (matched by SNI) | HTTP (matched by Host) | TCP (addresses only)
        package-mirror:
          addresses: [203.0.113.10/32]
          ports: [443]
          protocol: TCP
      infrastructure: { replicas: 2, podDisruptionBudget: { minAvailable: 1 } }
```

### `allowedHosts` entries (shape shared with `posture`)

Each entry has `enabled` (default true), exactly one of `hosts` (DNS names, wildcards like
`*.example.com` allowed) or `addresses` (IPs or CIDRs), `ports` (required, numeric), and
`protocol`:

- `TLS`: matched by the TLS server name (SNI). Hostnames only.
- `HTTP`: matched by the Host header. Hostnames only.
- `TCP`: matched by address and port. Addresses only; `TCP` with `hosts` fails, because a
  hostname can't be checked on plain TCP.

`posture`'s `egress.allowedHosts` uses the same shape, so an entry can be copied between the two.

## How it works (Istio ambient)

### Ingress

- One `Gateway` (`gatewayClassName: istio`) per enabled `ingress.gateways` entry, in the ingress
  namespace, named by its key. Each gateway gets its own Service and load-balancer address.
- `https`: HTTPS listeners terminate TLS with `certificateRefs` to Secrets in the same namespace;
  `redirectToHTTPS` on an HTTP listener renders an HTTPRoute that returns 301 to HTTPS.
- `tls-passthrough`: TLS listeners with `tls.mode: Passthrough`, for TLSRoutes routed by SNI.
- `tcp`: one TCP listener per entry, each accepting TCPRoutes only from its `namespace` (selected
  by `kubernetes.io/metadata.name`), so no other namespace can claim the port.
- Route attachment for `https` and `tls-passthrough`: each listener's `allowedRoutes.namespaces`
  is `from: Selector` on the label `ingress.boundary.posture.dev/<gateway>: "true"`. The label is
  set when a namespace is created, never in this chart's values.
- `infrastructure` renders a ConfigMap referenced by the Gateway's
  `spec.infrastructure.parametersRef`, patching the Deployment, Service, autoscaler, and
  disruption budget Istio generates, including what keeps the pods compliant with the `policy`
  chart: the seccomp profile, `automountServiceAccountToken: false`, and a liveness probe on
  `istio-proxy` (`/healthz/ready` on 15021, the endpoint of Istio's own readiness probe). The
  same patch serves egress waypoints.

### TLS settings (Istio)

Istio offers no Gateway API field for TLS versions or ciphers, so they're applied with one
`EnvoyFilter` per gateway, in the gateway's namespace:

- `workloadSelector` on `gateway.networking.k8s.io/gateway-name: <gateway>`.
- One `FILTER_CHAIN` `MERGE` patch per terminating listener, matched by `context: GATEWAY` and the
  listener's port, plus `filterChain.sni` when several listeners share a port with different
  hostnames (that's the granularity of a per-listener override).
- The patch sets `transport_socket` (`envoy.transport_sockets.tls`, typed config
  `type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext`) with
  `common_tls_context.tls_params`: `tls_minimum_protocol_version`,
  `tls_maximum_protocol_version`, and `cipher_suites` when set.
- Only TLS-terminating listeners: `tls` on a passthrough or TCP listener fails.
- EnvoyFilter patches Envoy internals, so it can break on Istio upgrades: the e2e checks the
  negotiated version and that certificates still load, and a new Istio version isn't supported
  until that passes.

### Egress

- One waypoint `Gateway` (`gatewayClassName: istio-waypoint`, label
  `istio.io/waypoint-for: service`) per enabled `egress.gateways` entry, in the egress namespace,
  with one HBONE listener (15008) admitting every namespace (`allowedRoutes.namespaces.from:
  All`): posture's ServiceEntries anywhere route to it, and its policies are the limit. Istio
  names the generated Deployment and Service after the Gateway (no `-istio` suffix).
- **The waypoint enforces a limit by destination, never by namespace.** One ALLOW
  `AuthorizationPolicy` per enabled `allowedHosts` entry, targeting the waypoint (`targetRefs`):
  `HTTP` by `to.operation.hosts` and ports, `TLS` by the `connection.sni` condition and ports,
  `TCP` by `destination.ip` and ports. Each waypoint also gets `deny-egress-via-<gateway>`, an
  ALLOW policy with no rules: Istio allows everything through a waypoint with no ALLOW policy,
  so this keeps a gateway with no enabled entries closed. Anything no entry matches is refused.
- **This chart creates no ServiceEntries.** Workloads ask for hosts through their own `posture`
  (`egress.allowedHosts`), which renders namespace-scoped ServiceEntries routed to the waypoint.
  A request outside this chart's list reaches the waypoint and is refused there.
- `exitNodes`, when set, pins the waypoint to those nodes: merged into the infrastructure
  ConfigMap's `nodeSelector` (a key also in `infrastructure.nodeSelector` must agree).
- Hostname ServiceEntries reach the waypoint only with ztunnel's DNS capture and istiod's IP
  auto-allocation (ambient defaults since Istio 1.25), a mesh prerequisite in the README.

### Mesh-wide

- `PeerAuthentication` `mtls-strict` (or `mtls-permissive`) in `istio.rootNamespace`.
- `meshDefaultDeny: true`: an allow-nothing `AuthorizationPolicy` named `deny-all` in the root
  namespace.
- `accessLogs`: a `Telemetry` resource per gateway and waypoint (`targetRefs`), using Istio's
  built-in `envoy` log provider.

## Other meshes (later phases)

| | Istio | Envoy Gateway (Linkerd, none) | Cilium |
|---|---|---|---|
| Ingress | Istio Gateway | Envoy Gateway, installed by this chart | Cilium Gateway API |
| TLS settings | EnvoyFilter | ClientTrafficPolicy | per Cilium phase |
| Egress gateway | waypoint | Linkerd: `EgressNetwork` limit, no gateway; none: not available | `exitNodes` only (CiliumEgressGatewayPolicy) |
| Cluster-wide host limit | waypoint authorization | Linkerd: `EgressNetwork` + routes | none: hostname egress is left to `posture` |
| Mesh-wide mTLS | PeerAuthentication | Linkerd: install-time setting (`inherit` only); none: `inherit` only | per Cilium phase |

## Conventions shared with `posture` and `policy`

| Convention | Default | Used by |
|---|---|---|
| Ingress namespace | `ingress-gateway` | boundary, posture's `istio-ingress` profile and `ingress-gateway` source |
| Egress namespace | `egress-gateway` | boundary, posture's `istio-egress` profile, `egress-gateway` destination, and `allowedHosts` |
| Default egress gateway name | `default` | boundary, posture's `allowedHosts` routing |
| Route attachment label | `ingress.boundary.posture.dev/<gateway>: "true"` | boundary, namespace creators |
| Gateway pod component label | `app.kubernetes.io/component: ingress-gateway` / `egress-waypoint` (plus `app.kubernetes.io/name: <gateway>`) | boundary (`spec.infrastructure.labels`), posture's `istio-ingress` / `istio-egress` exception |
| Route-hostname rule skips the ingress namespace | `restrict-route-hostnames.namespaces: [ingress-gateway]` | policy's values at the site (the redirect route has no hostnames) |
| `allowedHosts` shape | see above | boundary, posture |
| Gateway ports for posture | `https` 443/80, `tls-passthrough` 443 | boundary, posture's `istio-ingress` profile settings |

Renaming any of these is supported, but it must be changed in every chart that uses it.

## Naming

- Gateways: their map key (`https`, `tls-passthrough`, `tcp`, `default`).
- Egress limits: `allow-egress-via-<gateway>-to-<entry>` (`allow-egress-via-default-to-github`),
  and `deny-egress-via-<gateway>` (the allow-nothing policy).
- HTTPS redirect: `redirect-http-to-https-<gateway>`.
- TLS settings: `tls-<gateway>` (EnvoyFilter).
- Infrastructure ConfigMaps: `<gateway>-infrastructure`.
- Mesh-wide: `mtls-strict` / `mtls-permissive`, `deny-all`, `access-logs-<gateway>`.
- Names over 253 characters fail the render with the offending entry.

## Layout

```
charts/boundary/
  Chart.yaml  values.yaml  values.schema.json
  templates/
    _helpers.tpl        names, labels, annotations, the mesh and implementation switches
    _model.tpl          values -> normalized gateways, listeners, allowedHosts; derived
                        names, redirect port, and the per-listener TLS patches
    istio/              ingress gateways, egress waypoints, infrastructure, redirect,
                        tls (EnvoyFilter), egress authorization, mesh-wide, telemetry
    envoy-gateway/      phase 5
    linkerd/  cilium/   phases 5 and 7
    validate.yaml       builds the model on every render, so invalid values always fail
    NOTES.txt
  tests/                helm-unittest suites, one subfolder per output (tests/istio/)
examples/               values files that double as fixtures (lint, kubeconform, snapshots, e2e)
test/model-probe/       test-only chart rendering the model as YAML for unit tests
test/e2e/               k3d harness: run.sh, lib.sh, scenarios/<name>.sh; integration.sh and
                        values/integration/ (the whole stack under policy and posture)
test/release/           release scripts (tag check, dist build, notes) and their tag-cases
Makefile                pinned tool versions and every test target
README.md               install, usage, infrastructure keys, gateway pod compliance
CHANGELOG.md            one section per release; a tag v<version> must match it and Chart.yaml
docs/PLAN.md
```

## Testing

The harness is the one used by `posture`: pinned tools in `.bin/`, nothing installed globally.

    make tools            helm, helm-unittest, kubeconform (pinned in the Makefile)
    make test             lint (chart and every example), unittest (chart and model probe),
                          validate (kubeconform with the CRDs-catalog for Istio and Gateway API)
    make test-all-helm    make test under Helm 3.14, the latest 3.x, and 4
    make unittest-update  regenerate the example snapshots (review the diff)
    make e2e MESH=istio [E2E_ARGS=<scenario>] [E2E_KEEP=1] [E2E_REUSE=1]   needs Docker
    make e2e-integration MESH=istio [E2E_KEEP=1]   the whole stack, one script; needs Docker
    make release-check TAG=v<version>   build a release's assets into dist/, as the release
                          workflow does (make test runs check-release, the tag-check cases)

Unit tests: one `failedTemplate` case per render failure, matching `boundary: <path>: ...`;
normalization is asserted on the model through `test/model-probe`. e2e scenarios define
`setup`, `checks` (`expect allow|deny <ns>/<workload> <host>:<port>`), `install`, and
optionally `extra` and `teardown`; every check first runs before the chart is installed and must
connect, so a deny can't pass for the wrong reason.

The e2e cluster is k3d with the Gateway API CRDs (v1.6, standard), then Istio ambient
(`platform=k3d`), then `posture` in the two gateway namespaces, then this chart. Every behavior
needs an e2e case that shows the allowed path works and the refused path is refused.

The integration run (`test/e2e/integration.sh`, values in `test/e2e/values/integration/`) is a
separate cluster with Calico (so posture's NetworkPolicies are enforced), the pinned `policy`
chart with its defaults enforced, Istio's images by digest, and `posture` in every namespace, in
the README's install order. Its checks: gateway pods admitted with only the profile exception,
ingress through `https`, the egress limit, `restrict-route-hostnames`, and a clean uninstall.
The e2e workloads meet the policy defaults (images by digest, read-only root filesystem,
requests and a memory limit), so both runs use them.

## Status

| Phase | Area | Status |
|---|---|---|
| 1 | Skeleton, model, mesh-wide settings | done |
| 2 | Istio ingress gateways and TLS settings | done |
| 3 | Istio egress gateways | done |
| 4 | Integration with `posture` and `policy` (Istio) | done |
| 5 | Envoy Gateway ingress (Linkerd and no mesh) and Linkerd egress | not started |
| 6 | Linkerd and no-mesh integration | not started |
| 7 | Cilium | not started |
| 8 | Cilium integration | not started |
