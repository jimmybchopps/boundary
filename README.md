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
  release installed first. On a cluster running the `policy` chart, pods in a namespace without
  `posture-exceptions` are refused.
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
infrastructure ConfigMap, never through `posture` exceptions. Here is the comparison for Istio
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

**Optional policies that are on by default:** these still flag the generated pod. They're
resolved with the `policy` chart installed (docs/PLAN.md, phase 4):

| Policy | Finding |
|---|---|
| `disallow-mesh-opt-out` | Istio labels the pod `sidecar.istio.io/inject: "false"`, and the waypoint pod also `istio.io/dataplane-mode: none` |
| `require-standard-labels` | no `app.kubernetes.io/name` label |
| `require-image-digest` | the proxy image is pinned by tag, not digest |
| `restrict-loadbalancer-services` | the ingress gateway's default `LoadBalancer` Service needs the ingress namespace in the policy's `namespaces` (waypoints use ClusterIP) |
| `require-probes` (audit by default) | readiness and startup probes, but no liveness probe |

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
```

See [CLAUDE.md](CLAUDE.md) for the values contract and conventions, and [docs/PLAN.md](docs/PLAN.md) for
the build order.
