# boundary

A Helm chart for security at the edge of the cluster: the gateways traffic enters and leaves
through, the cluster-wide limit on where traffic may leave for, and the mesh-wide defaults that
apply to every namespace.

It is **mesh-aware, not mesh-installing**: it creates resources in the mesh that's already
running and never installs the mesh itself. Today it supports **Istio in ambient mode**: the
mesh-wide settings, the ingress gateways, and the egress gateways. Envoy Gateway with Linkerd or
no mesh, and Cilium follow (see [docs/PLAN.md](docs/PLAN.md)).

Companion charts: `policy` (the cluster's admission policies) and `posture` (each namespace's
network policies, authorization, and policy exceptions). boundary never references them; they
share a few conventions (namespace names, the route attachment label, the `allowedHosts`
shape).

## Prerequisites

This chart installs none of these:

- **Istio in ambient mode**, installed and healthy: istiod, istio-cni, ztunnel. Tested with
  Istio 1.32. Egress to host names also needs ztunnel's **DNS capture** and istiod's **IP
  auto-allocation** for ServiceEntries. Both are on by default in ambient mode since Istio
  1.25; don't turn them off (`cni.ambient.dnsCapture`, `PILOT_ENABLE_IP_AUTOALLOCATE`).
  Without them, a workload's request for a host name never reaches the egress waypoint.
- **The Kubernetes Gateway API CRDs**, v1.6.0 or later, standard channel. They must exist
  before Istio starts. Without them the install fails with an error like:

      no matches for kind "Gateway" in version "gateway.networking.k8s.io/v1"

  Install them, restart istiod, then install this chart again.

  Some distributions ship their own Gateway API CRDs. k3s, for example, ships them as the
  `gateway-api-crd` add-on. Check which version and channel are installed, or turn the add-on
  off and install the CRDs yourself.
- **The gateway namespaces**, `ingress-gateway` and `egress-gateway` by default. Each must be
  created, enrolled in the mesh (`istio.io/dataplane-mode=ambient`), and have its `posture`
  release installed first, with the profile `istio-ingress` or `istio-egress` (posture 0.2.0 or
  later). On a cluster running the `policy` chart, pods in a namespace without
  `posture-exceptions` are refused, and the gateway pods need the profile's one exception (see
  [Running under the policy chart](#running-under-the-policy-chart)).
- **TLS certificate Secrets** (`kubernetes.io/tls`) in the ingress namespace, named by the
  listeners' `certificates`. This chart only references them. Replacing a Secret takes effect
  without restarting the gateway.

## Install

```sh
helm install boundary ./charts/boundary -n istio-system -f values.yaml
```

Objects go into the namespaces they belong in (`istio.rootNamespace`, `ingress.namespace`,
`egress.namespace`), whatever the release namespace. Every value is checked by the chart's JSON schema and its model.
A setting the chart can't apply fails the install with the values path and the reason; it is
never silently ignored. Every object carries the annotation `boundary.posture.dev/rule`, the
values path it came from.

## Install order

On a cluster with every companion chart, install in this order. Each step needs the ones before
it, and the integration test (`make e2e-integration`) follows the same order:

1. The Gateway API CRDs.
2. Istio's CRDs (the `base` chart).
3. The `policy` chart. From here on, a pod in a namespace without `posture-exceptions` is
   refused.
4. `posture` in `istio-system`, profile `istio-system`.
5. istiod, istio-cni, and ztunnel.
6. The gateway namespaces, enrolled in the mesh, each with `posture` (profiles `istio-ingress`
   and `istio-egress`).
7. The TLS Secrets in the ingress namespace.
8. boundary.
9. Application namespaces, at any point after step 5: `posture` first, then their workloads
   and routes.

Uninstall in reverse: boundary, then the namespaces' `posture` releases and the namespaces,
then Istio, then `policy`.

## Running under the policy chart

boundary's gateway and waypoint pods pass the `policy` chart's defaults, enforced, with one
`posture` exception. A site sets these:

- **`posture` profiles in the gateway namespaces** (posture 0.2.0 or later). Istio labels its
  gateway pods `sidecar.istio.io/inject: "false"` (and waypoint pods also
  `istio.io/dataplane-mode: none`), which `disallow-mesh-opt-out` refuses. Those labels are what
  make the gateway Istio's own proxy rather than a workload in the mesh, so they stay. The
  `istio-ingress` and `istio-egress` profiles except the pods boundary labels
  `app.kubernetes.io/component: ingress-gateway` or `egress-waypoint` from that one policy.
  Everything else in the baseline, boundary fixes itself (see
  [Gateway pod compliance](#gateway-pod-compliance)).
- **`restrict-image-registries`**: the registry Istio's images come from (`docker.io/istio/` for
  the upstream images).
- **`restrict-loadbalancer-services`**: `namespaces: [ingress-gateway]` (`ingress.namespace`),
  so the ingress gateways' LoadBalancer Services are allowed there and nowhere else.
- **`restrict-route-hostnames`** (optional, policy 0.2.1 or later when turned on): list the
  ingress namespace in its `namespaces`. boundary's `redirect-http-to-https-<gateway>` route has
  no hostnames, because it answers every hostname on its HTTP listener, so it can't meet the
  rule. Only boundary's own routes can attach to that namespace's listeners.

  ```yaml
  policies:
    restrict-route-hostnames:
      enabled: true
      domains: [apps.example.mil]
      namespaces: [ingress-gateway]
  ```

- **Istio's install**: images pinned by digest (`require-image-digest`), as full references,
  and a memory limit for istiod and ztunnel (`require-resource-limits`):

  ```sh
  helm install istiod istio/istiod -n istio-system --set profile=ambient \
    --set image=docker.io/istio/pilot:1.32.0-distroless@sha256:<digest> \
    --set global.proxy.image=docker.io/istio/proxyv2:1.32.0-distroless@sha256:<digest> \
    --set resources.limits.memory=2Gi
  helm install ztunnel istio/ztunnel -n istio-system \
    --set image=docker.io/istio/ztunnel:1.32.0-distroless@sha256:<digest> \
    --set resources.limits.memory=1Gi
  ```

  `global.proxy.image` is also the gateways' and waypoints' proxy image. istio-cni runs in
  `kube-system`, which the policy chart doesn't evaluate. The Makefile pins the digests the
  tests use.

## Mesh-wide settings

| Value | Renders (in `istio.rootNamespace`) |
|---|---|
| `mtls.mode: STRICT` (default) | PeerAuthentication `mtls-strict` |
| `mtls.mode: PERMISSIVE` | PeerAuthentication `mtls-permissive` |
| `mtls.mode: inherit` | nothing |
| `meshDefaultDeny: true` | AuthorizationPolicy `deny-all`, which allows nothing |

## Ingress gateways

Each enabled entry in `ingress.gateways` becomes a Gateway (`gatewayClassName: istio`) in
`ingress.namespace`, with its own Deployment and Service (`<gateway>-istio`) and its own address.
Three gateways are defined:

| Gateway | Default | Listeners |
|---|---|---|
| `https` | on | `https` (443, terminates TLS with `apps-tls`), `http` (80, redirects to HTTPS) |
| `tls-passthrough` | off | `tls` (443, TLS passed through to the workload, routed by SNI) |
| `tcp` | off | none: add one listener per TCP service |

**Attaching routes.** A namespace opts in to the `https` and `tls-passthrough` gateways with the
label `ingress.boundary.posture.dev/<gateway>: "true"`, set when the namespace is created. Its
HTTPRoutes (or TLSRoutes) then reference the Gateway in the ingress namespace:

```yaml
parentRefs:
  - name: https
    namespace: ingress-gateway
```

Routes from namespaces without the label aren't accepted; the route's status shows
`NotAllowedByListeners`. An HTTP listener with `redirectToHTTPS` admits only the chart's own
redirect route, so every plain HTTP request gets a 301 to HTTPS.

**TCP services.** Raw TCP has no hostname, so each TCP service gets its own listener, which only
its namespace may use:

```yaml
ingress:
  gateways:
    tcp:
      enabled: true
      listeners:
        postgres: { port: 5432, protocol: TCP, namespace: databases }
```

**Several hostnames on one port.** Listeners may share a port when they share a protocol and
have different hostnames. HTTPS listeners that share a port each need a hostname, because their
TLS settings are matched by SNI.

### TLS settings

`tls` (minimum and maximum version, TLS 1.2 cipher suites) applies to every HTTPS listener. A
listener's own `tls` overrides it key by key. Istio has no Gateway API field for these settings,
so they're applied with one EnvoyFilter per gateway (`tls-<gateway>`). It patches each
terminating listener's TLS context, matched by port, and by SNI when listeners share a port.

EnvoyFilter patches Envoy's internals, so an Istio upgrade can break it. The e2e checks the
negotiated TLS versions and that certificates still load. Treat a new Istio version as
unsupported until those checks pass on it.

## Egress gateways

Each enabled entry in `egress.gateways` becomes an Istio **waypoint** in `egress.namespace`: a
Gateway with `gatewayClassName: istio-waypoint` and the label `istio.io/waypoint-for: service`,
whose Deployment and Service Istio names after the Gateway. One gateway, `default`, is defined;
exactly one enabled gateway has `default: true`.

**How traffic gets there.** This chart creates no ServiceEntries. A workload asks for a host
through its own `posture` release (`egress.allowedHosts`), which renders a ServiceEntry in the
workload's namespace labeled `istio.io/use-waypoint: <gateway>`. ztunnel then sends that
traffic to the waypoint. The waypoint's HBONE listener admits every namespace
(`allowedRoutes.namespaces.from: All`); the waypoint's own list decides where traffic may go.

**The limit.** The waypoint enforces it by destination, never by namespace. Each enabled
`allowedHosts` entry becomes an ALLOW AuthorizationPolicy targeting the waypoint,
`allow-egress-via-<gateway>-to-<entry>`:

| `protocol` | Matched by | Entry needs |
|---|---|---|
| `TLS` (default) | the TLS server name (`connection.sni`) and port | `hosts` |
| `HTTP` | the Host header (`to.operation.hosts`) and port | `hosts` |
| `TCP` | the destination address (`destination.ip`) and port | `addresses` |

Each waypoint also gets `deny-egress-via-<gateway>`, an ALLOW policy with no rules. Istio allows
everything through a waypoint that has no ALLOW policy, so without it a gateway with no enabled
entries would be open. With it, a request through the waypoint that no entry matches is
refused: a TLS connection is reset, and an HTTP request gets a 403.

```yaml
egress:
  gateways:
    default:
      allowedHosts:
        github: { hosts: [api.github.com], ports: [443], protocol: TLS }
        package-mirror: { addresses: [203.0.113.10/32], ports: [443], protocol: TCP }
```

The `allowedHosts` shape is the same as `posture`'s, so an entry can be copied between the two.

**Exit nodes.** `exitNodes` is a node selector for the waypoint's pods, so traffic leaves the
cluster from those nodes' addresses. It's merged into `infrastructure.nodeSelector`; a key set
in both must have the same value.

## Access logs

With `accessLogs.enabled` (the default), each ingress gateway and egress waypoint gets a
Telemetry (`access-logs-<gateway>`) using Istio's built-in `envoy` provider: one line per
request or connection on the pod's stdout.

## Infrastructure

Each gateway's and waypoint's `infrastructure` becomes a ConfigMap, `<gateway>-infrastructure`, referenced by
the Gateway's `spec.infrastructure.parametersRef`. Istio applies each key as a strategic-merge
patch to what it generates for the Gateway. Istio 1.32 reads these keys:

| Key | Patches | Set by this chart |
|---|---|---|
| `deployment` | the Deployment | always: pod `seccompProfile: RuntimeDefault`; `replicas` (unless autoscaling); with `topologySpread`, a spread across nodes; `nodeSelector`, `tolerations`, and the `istio-proxy` container's `resources`, when set |
| `service` | the Service | `metadata.annotations`, when `service.annotations` is set (ingress only; a waypoint's Service is ClusterIP) |
| `horizontalPodAutoscaler` | an HPA, created only when the key is present | `minReplicas` and `maxReplicas`, when `autoscaling.enabled` |
| `podDisruptionBudget` | a PDB, created only when the key is present | always: `minAvailable` |
| `serviceAccount` | the ServiceAccount | not used |

For ingress gateways, the Service type is passed to Istio with the Gateway annotation
`networking.istio.io/service-type`. `service.loadBalancerIP` becomes the Gateway's
`spec.addresses`. Waypoints take `exitNodes` as well (see above).

## Gateway pod compliance

The pods Istio generates are made to pass the `policy` chart's baseline through the
infrastructure ConfigMap and the Gateway's `spec.infrastructure.labels`, never through
`posture` exceptions. The one exception, `disallow-mesh-opt-out` (an optional policy), comes
from `posture`'s gateway profiles. Here is the comparison for Istio
1.32's generated gateway pod (`kube-gateway.yaml`) and waypoint pod (`waypoint.yaml`); both
pass every baked-in row. The e2e checks the baked-in rows on a live cluster for
both.

**Baked-in policies (always enforced):**

| Policy | Generated pod | Result |
|---|---|---|
| `disallow-host-namespaces` | no hostNetwork, hostPID, or hostIPC | passes |
| `disallow-host-path` | volumes: emptyDir, downwardAPI, projected (the waypoint also a configMap) | passes |
| `disallow-host-ports` | no hostPort | passes |
| `disallow-privilege-escalation` | `allowPrivilegeEscalation: false` | passes |
| `disallow-privileged-containers` | `privileged: false` | passes |
| `require-drop-all-capabilities` | drops ALL, adds nothing | passes |
| `require-run-as-non-root` | `runAsNonRoot: true`, uid 1337 | passes |
| `restrict-apparmor` | not set | passes |
| `restrict-external-ips` | the Service sets no externalIPs | passes |
| `restrict-image-registries` | Istio's proxy image | site-specific: list the registry the proxy image comes from |
| `restrict-proc-mount` | default | passes |
| `restrict-seccomp` | **unset by Istio** | **fixed**: the ConfigMap sets `RuntimeDefault` |
| `restrict-selinux` | not set | passes |
| `restrict-sysctls` | gateway: `net.ipv4.ip_unprivileged_port_start` only, a safe sysctl; waypoint: none | passes |
| `restrict-volume-types` | emptyDir, downwardAPI, projected, configMap (waypoint) | passes |

**Optional policies that are on by default.** The integration test checks these with the
`policy` chart's defaults enforced:

| Policy | Generated pod | Result |
|---|---|---|
| `disallow-mesh-opt-out` | Istio labels the pod `sidecar.istio.io/inject: "false"`, and the waypoint pod also `istio.io/dataplane-mode: none` | **excepted** by `posture`'s `istio-ingress` and `istio-egress` profiles, selected by the component label below |
| `require-standard-labels` | Istio sets no `app.kubernetes.io/name` | **fixed**: the Gateway's `spec.infrastructure.labels` sets `app.kubernetes.io/name: <gateway>` and `app.kubernetes.io/component: ingress-gateway` or `egress-waypoint` |
| `require-image-digest` | the proxy image as Istio is configured | site-specific: install Istio with `global.proxy.image` pinned by digest |
| `restrict-loadbalancer-services` | the ingress gateway's default `LoadBalancer` Service | site-specific: list the ingress namespace in the policy's `namespaces` (waypoints use ClusterIP) |
| `require-probes` (audit by default) | readiness and startup probes, but no liveness probe | reported, not refused |

`require-read-only-root-filesystem` and `require-resource-limits` pass. Istio sets a read-only
root filesystem. The gateway's default resources (`global.proxy.resources`) include CPU and
memory requests and a memory limit; the waypoint's (`global.waypoint.resources`) include
requests and both limits.

## Development

Tests follow the same harness as `posture`. Tools are pinned in the [Makefile](Makefile) and
installed into `.bin/`.

```sh
make tools            # helm, helm-unittest, kubeconform
make test             # lint, unit tests, kubeconform on every example
make test-all-helm    # the same under Helm 3.14, the latest 3.x, and 4
make e2e MESH=istio   # k3d end-to-end tests (Docker and openssl); E2E_ARGS=<scenario> E2E_KEEP=1
make e2e-integration MESH=istio   # the whole stack under policy and posture, then uninstall; E2E_KEEP=1
```

See [CLAUDE.md](CLAUDE.md) for the values contract and conventions, and [docs/PLAN.md](docs/PLAN.md) for
the build order.
