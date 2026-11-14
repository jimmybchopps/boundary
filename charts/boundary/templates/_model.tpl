{{/*
The model: values normalized once into what every renderer reads. Renderers call:

  {{- $model := include "boundary.model" . | fromJson -}}

Shape:

  mesh: istio                             # the only mesh implemented so far
  implementation: istio                   # ingress.implementation, resolved from mesh
  rootNamespace: istio-system             # istio.rootNamespace
  mtls: { mode, name }                    # name: mtls-strict | mtls-permissive | "" (inherit)
  meshDefaultDeny: false
  accessLogs: { enabled }
  tls: { minVersion, maxVersion, cipherSuites }   # chart-wide, defaults filled in
  ingress:
    namespace: ingress-gateway
    gateways:                             # enabled only, sorted by name
      - name, path                        # path: ingress.gateways.<name>
        service: { type, annotations, loadBalancerIP }    # defaults filled in
        infrastructure: { ... }           # boundary.infrastructureDefaults, then the values
        listeners:                        # enabled only, sorted by name
          - name, path, port, protocol, hostname
            certificates, tls             # HTTPS only; tls is the chart-wide tls with the
                                          # listener's overrides applied
            redirectToHTTPS               # HTTP only
            namespace                     # TCP only
  egress:
    namespace: egress-gateway
    default: default                      # the enabled gateway with default: true ("" if none)
    gateways:                             # enabled only, sorted by name
      - name, path, default, exitNodes, infrastructure
        allowedHosts:                     # enabled only, sorted by name
          - name, path, policyName        # allow-egress-via-<gateway>-to-<entry>
            hosts | addresses, ports, protocol

Every entry is checked, enabled or not, so a mistake never hides behind enabled: false.
Checks that depend on the surroundings apply only to enabled entries: a gateway's listener
count, and the count of default egress gateways. A disabled gateway drops everything under it.

Every failure names the values path: "boundary: <path>: <reason>".

Note: fromJson turns numbers into float64. Renderers must use `int` on port numbers before
formatting them with printf.
*/}}
{{- define "boundary.model" -}}
{{- $v := .Values -}}
{{- $mesh := $v.mesh | default "istio" -}}
{{- $implementation := include "boundary.implementation" . -}}

{{- /* Combinations whose phase hasn't landed. */ -}}
{{- if ne $mesh "istio" -}}
{{- fail (printf "boundary: mesh: %q isn't supported yet (phase %s adds it)" $mesh (get (dict "linkerd" "5" "none" "5" "cilium" "7") $mesh)) -}}
{{- end -}}
{{- if ne $implementation "istio" -}}
{{- fail (printf "boundary: ingress.implementation: %q isn't supported yet (phase %s adds it)" $implementation (get (dict "envoy-gateway" "5" "cilium" "7") $implementation)) -}}
{{- end -}}

{{- /* Chart-wide TLS settings. */ -}}
{{- $tlsValues := $v.tls | default dict -}}
{{- $tls := dict
      "minVersion" ($tlsValues.minVersion | default "TLSv1_2")
      "maxVersion" ($tlsValues.maxVersion | default "TLSv1_3")
      "cipherSuites" ($tlsValues.cipherSuites | default list) -}}
{{- include "boundary.checkTLS" (dict "tls" $tls "path" "tls") -}}

{{- /* Ingress gateways. */ -}}
{{- $ingressValues := $v.ingress | default dict -}}
{{- $ingressGateways := list -}}
{{- range $gatewayName, $gateway := $ingressValues.gateways | default dict -}}
  {{- $gateway = $gateway | default dict -}}
  {{- $gatewayPath := printf "ingress.gateways.%s" $gatewayName -}}
  {{- $listeners := list -}}
  {{- range $listenerName, $listener := $gateway.listeners | default dict -}}
    {{- $listener = $listener | default dict -}}
    {{- $out := dict -}}
    {{- include "boundary.listener" (dict "listener" $listener "name" $listenerName
          "path" (printf "%s.listeners.%s" $gatewayPath $listenerName) "tls" $tls "out" $out) -}}
    {{- if eq (include "boundary.enabled" $listener) "true" -}}
      {{- $listeners = append $listeners $out -}}
    {{- end -}}
  {{- end -}}
  {{- if eq (include "boundary.enabled" $gateway) "true" -}}
    {{- if not $listeners -}}
      {{- fail (printf "boundary: %s: an enabled gateway needs at least one enabled listener" $gatewayPath) -}}
    {{- end -}}
    {{- $service := mustMergeOverwrite
          (dict "type" "LoadBalancer" "annotations" dict "loadBalancerIP" "")
          (deepCopy ($gateway.service | default dict)) -}}
    {{- $ingressGateways = append $ingressGateways (dict
          "name" (include "boundary.name" (dict "name" $gatewayName "path" $gatewayPath))
          "path" $gatewayPath
          "service" $service
          "infrastructure" (include "boundary.infrastructure" $gateway.infrastructure | fromJson)
          "listeners" $listeners) -}}
  {{- end -}}
{{- end -}}

{{- /* Egress gateways (waypoints) and their allowed hosts. */ -}}
{{- $egressValues := $v.egress | default dict -}}
{{- $egressGateways := list -}}
{{- $defaults := list -}}
{{- range $gatewayName, $gateway := $egressValues.gateways | default dict -}}
  {{- $gateway = $gateway | default dict -}}
  {{- $gatewayPath := printf "egress.gateways.%s" $gatewayName -}}
  {{- $hosts := list -}}
  {{- range $entryName, $entry := $gateway.allowedHosts | default dict -}}
    {{- $entry = $entry | default dict -}}
    {{- $out := dict -}}
    {{- include "boundary.allowedHost" (dict "entry" $entry "name" $entryName "gateway" $gatewayName
          "path" (printf "%s.allowedHosts.%s" $gatewayPath $entryName) "out" $out) -}}
    {{- if eq (include "boundary.enabled" $entry) "true" -}}
      {{- $hosts = append $hosts $out -}}
    {{- end -}}
  {{- end -}}
  {{- if eq (include "boundary.enabled" $gateway) "true" -}}
    {{- $isDefault := eq (toString $gateway.default) "true" -}}
    {{- if $isDefault -}}{{- $defaults = append $defaults $gatewayName -}}{{- end -}}
    {{- $egressGateways = append $egressGateways (dict
          "name" (include "boundary.name" (dict "name" $gatewayName "path" $gatewayPath))
          "path" $gatewayPath
          "default" $isDefault
          "exitNodes" ($gateway.exitNodes | default dict)
          "infrastructure" (include "boundary.infrastructure" $gateway.infrastructure | fromJson)
          "allowedHosts" $hosts) -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $defaults) 1 -}}
{{- fail (printf "boundary: egress.gateways: exactly one enabled gateway may have default: true; %d do: %s" (len $defaults) (join ", " $defaults)) -}}
{{- end -}}
{{- if and $egressGateways (not $defaults) -}}
{{- $names := list -}}
{{- range $egressGateways -}}{{- $names = append $names .name -}}{{- end -}}
{{- fail (printf "boundary: egress.gateways: one enabled gateway needs default: true; none of %s has it" (join ", " $names)) -}}
{{- end -}}

{{- /* Mesh-wide settings. */ -}}
{{- $mode := (($v.mtls | default dict).mode) | default "STRICT" -}}
{{- $mtlsName := get (dict "STRICT" "mtls-strict" "PERMISSIVE" "mtls-permissive") $mode | default "" -}}

{{- $model := dict
      "mesh" $mesh
      "implementation" $implementation
      "rootNamespace" ((($v.istio | default dict).rootNamespace) | default "istio-system")
      "mtls" (dict "mode" $mode "name" $mtlsName)
      "meshDefaultDeny" (eq (toString $v.meshDefaultDeny) "true")
      "accessLogs" (dict "enabled" (ne (toString (($v.accessLogs | default dict).enabled)) "false"))
      "tls" $tls
      "ingress" (dict
        "namespace" ($ingressValues.namespace | default "ingress-gateway")
        "gateways" $ingressGateways)
      "egress" (dict
        "namespace" ($egressValues.namespace | default "egress-gateway")
        "default" (first $defaults | default "")
        "gateways" $egressGateways) -}}
{{- toJson $model -}}
{{- end -}}

{{/*
Checks a listener and sets its normalized fields on "out".
Usage: include "boundary.listener" (dict "listener" $l "name" "https"
         "path" "ingress.gateways.https.listeners.https" "tls" $chartTLS "out" $out)
*/}}
{{- define "boundary.listener" -}}
{{- $l := .listener -}}
{{- $path := .path -}}
{{- $protocol := $l.protocol | default "" -}}
{{- $what := get (dict
      "HTTP" "carries plaintext HTTP"
      "TLS" "passes TLS through to the workload, which terminates it"
      "TCP" "carries raw TCP") $protocol -}}
{{- $_ := set .out "name" .name -}}
{{- $_ := set .out "path" $path -}}
{{- $_ := set .out "port" (int $l.port) -}}
{{- $_ := set .out "protocol" $protocol -}}
{{- $_ := set .out "hostname" ($l.hostname | default "") -}}
{{- if eq $protocol "HTTPS" -}}
  {{- if not $l.certificates -}}
    {{- fail (printf "boundary: %s: an HTTPS listener needs certificates (Secret names in the ingress namespace)" $path) -}}
  {{- end -}}
  {{- $override := $l.tls | default dict -}}
  {{- $tls := dict
        "minVersion" ($override.minVersion | default .tls.minVersion)
        "maxVersion" ($override.maxVersion | default .tls.maxVersion)
        "cipherSuites" (ternary $override.cipherSuites .tls.cipherSuites (hasKey $override "cipherSuites")) -}}
  {{- include "boundary.checkTLS" (dict "tls" $tls "path" (printf "%s.tls" $path)) -}}
  {{- $_ := set .out "certificates" $l.certificates -}}
  {{- $_ := set .out "tls" $tls -}}
{{- else -}}
  {{- if hasKey $l "tls" -}}
    {{- fail (printf "boundary: %s: tls applies only to HTTPS listeners, which terminate TLS; a %s listener %s" $path $protocol $what) -}}
  {{- end -}}
  {{- if hasKey $l "certificates" -}}
    {{- fail (printf "boundary: %s: certificates apply only to HTTPS listeners; a %s listener %s" $path $protocol $what) -}}
  {{- end -}}
{{- end -}}
{{- if eq $protocol "HTTP" -}}
  {{- $_ := set .out "redirectToHTTPS" (eq (toString $l.redirectToHTTPS) "true") -}}
{{- else if eq (toString $l.redirectToHTTPS) "true" -}}
  {{- fail (printf "boundary: %s: redirectToHTTPS applies only to HTTP listeners; this one is %s" $path $protocol) -}}
{{- end -}}
{{- if eq $protocol "TCP" -}}
  {{- if not $l.namespace -}}
    {{- fail (printf "boundary: %s: a TCP listener needs namespace, the only namespace allowed to attach a TCPRoute to it" $path) -}}
  {{- end -}}
  {{- if $l.hostname -}}
    {{- fail (printf "boundary: %s: hostname doesn't apply to a TCP listener (raw TCP has no host name to match)" $path) -}}
  {{- end -}}
  {{- $_ := set .out "namespace" $l.namespace -}}
{{- else if $l.namespace -}}
  {{- fail (printf "boundary: %s: namespace applies only to TCP listeners; %s listeners admit routes from the namespaces labeled ingress.boundary.posture.dev/<gateway>" $path $protocol) -}}
{{- end -}}
{{- end -}}

{{/*
Checks an allowedHosts entry and sets its normalized fields on "out".
Usage: include "boundary.allowedHost" (dict "entry" $e "name" "github" "gateway" "default"
         "path" "egress.gateways.default.allowedHosts.github" "out" $out)
*/}}
{{- define "boundary.allowedHost" -}}
{{- $e := .entry -}}
{{- $path := .path -}}
{{- $hasHosts := not (empty $e.hosts) -}}
{{- $hasAddresses := not (empty $e.addresses) -}}
{{- if and $hasHosts $hasAddresses -}}
  {{- fail (printf "boundary: %s: set hosts or addresses, not both" $path) -}}
{{- end -}}
{{- if not (or $hasHosts $hasAddresses) -}}
  {{- fail (printf "boundary: %s: hosts or addresses is required (a non-empty list)" $path) -}}
{{- end -}}
{{- if empty $e.ports -}}
  {{- fail (printf "boundary: %s: ports are required (a non-empty list)" $path) -}}
{{- end -}}
{{- $protocol := $e.protocol | default "TLS" -}}
{{- if and $hasHosts (eq $protocol "TCP") -}}
  {{- fail (printf "boundary: %s: TCP can't be matched by host name; use addresses, or protocol TLS or HTTP" $path) -}}
{{- end -}}
{{- if and $hasAddresses (ne $protocol "TCP") -}}
  {{- fail (printf "boundary: %s: %s is matched by host name (%s), so it needs hosts; use protocol TCP for addresses" $path $protocol (ternary "the TLS server name" "the Host header" (eq $protocol "TLS"))) -}}
{{- end -}}
{{- $ports := list -}}
{{- range $e.ports -}}{{- $ports = append $ports (int .) -}}{{- end -}}
{{- $_ := set .out "name" .name -}}
{{- $_ := set .out "path" $path -}}
{{- $_ := set .out "policyName" (include "boundary.name" (dict "name" (printf "allow-egress-via-%s-to-%s" .gateway .name) "path" $path)) -}}
{{- if $hasHosts -}}
  {{- $_ := set .out "hosts" $e.hosts -}}
{{- else -}}
  {{- $_ := set .out "addresses" $e.addresses -}}
{{- end -}}
{{- $_ := set .out "ports" $ports -}}
{{- $_ := set .out "protocol" $protocol -}}
{{- end -}}

{{/*
Fails if minVersion is above maxVersion.
Usage: include "boundary.checkTLS" (dict "tls" $tls "path" "tls")
*/}}
{{- define "boundary.checkTLS" -}}
{{- if gt .tls.minVersion .tls.maxVersion -}}
{{- fail (printf "boundary: %s: minVersion %s is above maxVersion %s" .path .tls.minVersion .tls.maxVersion) -}}
{{- end -}}
{{- end -}}

{{/*
A gateway's infrastructure settings, as JSON: these defaults, then the values given.
Usage: include "boundary.infrastructure" $gateway.infrastructure | fromJson
*/}}
{{- define "boundary.infrastructure" -}}
{{- $defaults := dict
      "replicas" 2
      "autoscaling" (dict "enabled" false "minReplicas" 2 "maxReplicas" 5)
      "podDisruptionBudget" (dict "minAvailable" 1)
      "topologySpread" true
      "nodeSelector" dict
      "tolerations" list
      "resources" dict -}}
{{- toJson (mustMergeOverwrite $defaults (deepCopy (. | default dict))) -}}
{{- end -}}
