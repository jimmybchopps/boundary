# boundary: development plan

Eight phases: four for Istio ambient (skeleton, ingress, egress, integration), then Envoy
Gateway with Linkerd and no mesh (implementation, integration), then Cilium (implementation,
integration). The values contract, conventions, and naming are in `CLAUDE.md`.

Each phase ends with its acceptance criteria passing in CI.

---

## Phase 1: skeleton, model, mesh-wide settings

- [x] `charts/boundary/` with `Chart.yaml` (required Gateway API version and channel in
      annotations), `values.yaml` documenting every key, `values.schema.json`, `_helpers.tpl`.
- [x] Tooling pinned in a `Makefile` or `.tool-versions`: helm (3.14+ and 4), helm-unittest,
      kubeconform, k3d, kubectl, istioctl.
- [ ] CI: lint, unit tests, kubeconform with Gateway API and Istio CRD schemas.
- [x] `_model.tpl`: normalize gateways, listeners, and `allowedHosts`, dropping disabled
      entries. Render failures, each naming the entry:
      - a `mesh` or `ingress.implementation` whose phase hasn't landed;
      - enabled egress gateways with zero or several `default: true`;
      - an `allowedHosts` entry with both or neither of `hosts` and `addresses`, missing
        `ports`, or `TCP` with `hosts`;
      - an HTTPS listener without `certificates`;
      - `tls` on a passthrough or TCP listener;
      - a `tcp` listener without `namespace`.
- [x] Mesh-wide resources: `PeerAuthentication` (`mtls-strict` by default), the optional
      `deny-all`, annotations on everything.
- [x] `test/e2e/` harness: k3d, Gateway API CRDs v1.6 (standard), Istio ambient with
      `platform=k3d`, the two gateway namespaces created and enrolled in ambient, `posture`
      installed in each (exceptions only, until the profiles exist).
- [x] e2e: with STRICT, a pod outside the mesh can't reach a meshed pod; with PERMISSIVE it can.

**Done when** the chart installs on the harness and the mTLS e2e passes.

---

## Phase 2: Istio ingress gateways and TLS settings

- [ ] A Gateway per enabled `ingress.gateways` entry; the defaults `https` (on),
      `tls-passthrough` (off), and `tcp` (off) from CLAUDE.md.
- [ ] `https`: HTTPS listeners with `certificateRefs` to Secrets in the ingress namespace; the
      HTTP listener's redirect HTTPRoute.
- [ ] `tls-passthrough`: TLS listeners in Passthrough mode.
- [ ] `tcp`: one listener per entry, restricted to its `namespace`.
- [ ] Route attachment by the per-gateway label for `https` and `tls-passthrough`.
- [ ] Infrastructure ConfigMap via `parametersRef`. Confirm which keys the pinned Istio version
      supports and document them.
- [ ] Gateway pod compliance: compare the Deployment Istio generates with the `policy` chart's
      baked-in baseline and fill any gaps through the infrastructure ConfigMap. Record the
      result in the README.
- [ ] TLS settings: the chart-wide `tls` with per-listener overrides, rendered as one EnvoyFilter
      per gateway as described in CLAUDE.md (port match, plus SNI match when listeners share a
      port).
- [ ] `accessLogs` for each ingress gateway.
- [ ] Unit tests for every listener type, override, and failure. e2e:
      - a labeled namespace's HTTPRoute serves traffic through `https`;
      - an unlabeled namespace's HTTPRoute isn't accepted (route status shows it);
      - HTTP redirects to HTTPS;
      - the negotiated TLS version follows the chart-wide setting and a listener override
        (checked with `openssl s_client` or `curl --tls-max`), and certificates still load;
      - a TLSRoute through `tls-passthrough` reaches a workload that terminates TLS itself;
      - a TCPRoute from the listener's namespace works, and one from another namespace isn't
        accepted;
      - rotating the certificate Secret takes effect without restarting the gateway.

**Done when** every e2e case above passes.

---

## Phase 3: Istio egress gateways

- [ ] A waypoint Gateway per enabled `egress.gateways` entry (`istio-waypoint`,
      `istio.io/waypoint-for: service`), with its infrastructure ConfigMap and access logs.
- [ ] `exitNodes`: node selector on the waypoint only when set.
- [ ] ALLOW AuthorizationPolicies per enabled `allowedHosts` entry, targeting the waypoint:
      `HTTP` by host, `TLS` by `connection.sni`, `TCP` by `destination.ip`, each with its ports.
- [ ] Confirm whether ztunnel's DNS proxying (a mesh setting) is needed for hostname
      ServiceEntries to route through the waypoint, and list it as a mesh prerequisite if so.
- [ ] e2e, using a hand-written namespace-scoped ServiceEntry routed to the waypoint (shaped as
      `posture` will render it):
      - a host in the list is reached through the waypoint (seen in its access log);
      - a host not in the list reaches the waypoint and is refused;
      - `TLS` matches on SNI, `HTTP` on Host, `TCP` on address;
      - with two egress gateways, a ServiceEntry naming the second routes there;
      - with `exitNodes` set, the waypoint runs only on those nodes.

**Done when** every e2e case above passes.

---

## Phase 4: integration with `posture` and `policy` (Istio)

The full stack on one cluster: Gateway API CRDs, `policy`, Istio ambient, `posture` in every
namespace (profiles `istio-system`, `istio-ingress`, `istio-egress` where they apply), then this
chart.

- [ ] Gateway and waypoint pods are admitted under the `policy` baseline with an **empty**
      `posture-exceptions` object. If `disallow-mesh-opt-out` or another policy flags Istio's
      generated pods, fix it in the infrastructure ConfigMap, or add the exception to the
      `posture` gateway profile and document why.
- [ ] Ingress: an application namespace with its `posture` (the `ingress-gateway` source), the
      route label, and an HTTPRoute is reachable through `https`.
- [ ] Egress: an application whose `posture` lists a host in `egress.allowedHosts`:
      - reaches it through the default gateway when this chart's list includes it;
      - is refused at the waypoint when it doesn't;
      - another namespace that didn't list the host can't reach it.
- [ ] With the optional `policy` route-hostname rule enabled, a route claiming another
      namespace's hostname is denied at admission.
- [ ] A clean install and uninstall in the documented order leaves no stuck resources.

**Done when** every case above passes on one cluster from a single script.

---

## Phase 5: Envoy Gateway ingress (Linkerd and no mesh) and Linkerd egress

- [ ] Envoy Gateway's controller as an unmodified upstream chart dependency, enabled when
      `ingress.implementation` resolves to `envoy-gateway`; its CRDs stay a prerequisite.
- [ ] Proxies run in the Gateway's own namespace (Envoy Gateway's option for that), so the
      `ingress-gateway` convention holds; the controller's namespace needs its own `posture`
      (an `envoy-gateway` profile in `posture`).
- [ ] The same `ingress.gateways` values rendered for Envoy Gateway: Gateway class, listeners,
      certificates, route attachment, infrastructure through its proxy configuration resource.
- [ ] TLS settings through ClientTrafficPolicy, targeting each Gateway and listener.
- [ ] `mesh: linkerd`: proxies injected with Linkerd's proxy (so gateway-to-backend traffic gets
      Linkerd mTLS); the cluster-wide host limit as an `EgressNetwork` in Linkerd's cluster-wide
      egress namespace with `trafficPolicy: Deny`, plus a TLSRoute or HTTPRoute per allowed host;
      `exitNodes` fails (Linkerd has no egress gateway); `mtls` must be `inherit` (Linkerd's
      default policy is install-time configuration).
- [ ] `mesh: none`: ingress only. Egress gateways fail (no mesh can check hostnames), and `mtls`
      must be `inherit`.
- [ ] Unit tests and e2e mirroring phase 2 for both meshes, and phase 3's limit for Linkerd.

## Phase 6: Linkerd and no-mesh integration

- [ ] Phase 4's checks with Linkerd, `posture`'s Envoy Gateway and Linkerd profiles, and
      `policy`.
- [ ] The same ingress checks on a cluster with no mesh.

## Phase 7: Cilium

- [ ] Ingress through Cilium's Gateway API (`gatewayClassName: cilium`). The Service is created
      in the ingress namespace; the proxy is Cilium's shared Envoy, so infrastructure settings
      map to Cilium configuration where they exist and fail where they don't.
- [ ] TLS settings: Cilium's mechanism, found at the start of the phase.
- [ ] Egress: `exitNodes` maps to `CiliumEgressGatewayPolicy` (address destinations only).
      `allowedHosts` fails with an explanation: Cilium policies only allow, so a cluster-wide
      list can't limit what a namespace's `posture` allows. Hostname egress is `posture`'s alone.
- [ ] Unit tests and e2e mirroring phases 2 and 3 where the features exist.

## Phase 8: Cilium integration

- [ ] Phase 4's checks with Cilium, `posture`'s Cilium profiles, and `policy`.

---

## Changes needed in other repos

Listed here so the conventions stay in step; each is done in its own repo.

**`posture`** (its phase 5): built-in profiles (`istio-system`, `istio-ingress`,
`istio-egress`; later `envoy-gateway` and Linkerd's), `enabled` on every rule and reference,
`destinations` references as a map, gateway presets in `ingress-gateway` and `egress-gateway`,
and `egress.allowedHosts` in the shared shape.

**`policy`**: optional `restrict-route-hostnames` (route hostnames must be
`<namespace>.<domain>` or under it), and optionally `restrict-service-entries` (who may create
ServiceEntries; not needed for the egress limit, which the waypoint enforces).

---

## Settled

- The chart doesn't install the mesh, the Gateway API CRDs (v1.6+, standard channel), or Envoy
  Gateway's CRDs; it does install Envoy Gateway's controller when it's the ingress.
- Ingress gateways `https` (default), `tls-passthrough`, and `tcp` (optional), each its own
  Gateway and address; `tcp` listeners are added per service, each tied to one namespace.
- TLS settings are chart-wide with per-listener overrides; Istio applies them with an
  EnvoyFilter per gateway, Envoy Gateway with ClientTrafficPolicy.
- The egress limit is enforced at the waypoint by destination; namespaces request hosts through
  `posture`; exactly one egress gateway is the default; exit-node pinning is optional.
- Cilium has no cluster-wide hostname limit; `posture` handles hostname egress there.
- Certificates live in the gateway's namespace; ReferenceGrant is deferred.

## Later

- Cross-namespace certificate references with ReferenceGrant.
- Multi-cluster: east-west gateways, remote secrets, shared trust.
