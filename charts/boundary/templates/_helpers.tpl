{{/*
Common labels for every object this chart renders.
*/}}
{{- define "boundary.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
The annotation saying why an object exists: the values path it came from.
Usage: include "boundary.annotations" "mtls.mode"
*/}}
{{- define "boundary.annotations" -}}
boundary.posture.dev/rule: {{ . | quote }}
{{- end -}}

{{/*
An object name, checked against Kubernetes' 253-character limit; "path" is the values path
named in the error.
Usage: include "boundary.name" (dict "name" "allow-egress-via-default-to-github"
         "path" "egress.gateways.default.allowedHosts.github")
*/}}
{{- define "boundary.name" -}}
{{- if gt (len .name) 253 -}}
{{- fail (printf "boundary: %s: object name %q is %d characters; the limit is 253" .path .name (len .name)) -}}
{{- end -}}
{{- .name -}}
{{- end -}}

{{/*
The ingress implementation: ingress.implementation, or when empty, the mesh's
(istio -> istio, cilium -> cilium, linkerd and none -> envoy-gateway).
Usage: include "boundary.implementation" .
*/}}
{{- define "boundary.implementation" -}}
{{- $implementation := (.Values.ingress | default dict).implementation | default "" -}}
{{- if $implementation -}}
{{- $implementation -}}
{{- else -}}
{{- $mesh := .Values.mesh | default "istio" -}}
{{- get (dict "istio" "istio" "cilium" "cilium" "linkerd" "envoy-gateway" "none" "envoy-gateway") $mesh | default "envoy-gateway" -}}
{{- end -}}
{{- end -}}

{{/*
"true" or "false": whether a map entry is enabled (enabled defaults to true).
Usage: eq (include "boundary.enabled" $entry) "true"
*/}}
{{- define "boundary.enabled" -}}
{{- if and (kindIs "map" .) (hasKey . "enabled") -}}
{{- ternary "true" "false" (eq (toString .enabled) "true") -}}
{{- else -}}
true
{{- end -}}
{{- end -}}
