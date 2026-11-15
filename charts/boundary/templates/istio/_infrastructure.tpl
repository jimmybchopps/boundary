{{/*
The data of an Istio gateway's infrastructure ConfigMap (referenced by the Gateway's
spec.infrastructure.parametersRef): strategic-merge patches Istio applies to what it generates
for the Gateway. Istio 1.32 reads the keys deployment, service, serviceAccount,
horizontalPodAutoscaler, and podDisruptionBudget; the HPA and PDB exist only when their key is
present. Used for ingress gateways and egress waypoints (which have no service settings).

The deployment patch always sets the pod's seccomp profile to RuntimeDefault: Istio leaves it
unset, and the policy chart's baked-in restrict-seccomp requires it. Everything else Istio
generates already meets the baked-in policies (README, "Gateway pod compliance").

Usage: include "boundary.istio.infrastructure" $gateway   (a gateway from the model)
*/}}
{{- define "boundary.istio.infrastructure" -}}
{{- $i := .infrastructure -}}
{{- $podSpec := dict "securityContext" (dict "seccompProfile" (dict "type" "RuntimeDefault")) -}}
{{- if $i.topologySpread -}}
  {{- $_ := set $podSpec "topologySpreadConstraints" (list (dict
        "maxSkew" 1
        "topologyKey" "kubernetes.io/hostname"
        "whenUnsatisfiable" "ScheduleAnyway"
        "labelSelector" (dict "matchLabels" (dict "gateway.networking.k8s.io/gateway-name" .name)))) -}}
{{- end -}}
{{- with $i.nodeSelector }}{{ $_ := set $podSpec "nodeSelector" . }}{{ end -}}
{{- with $i.tolerations }}{{ $_ := set $podSpec "tolerations" . }}{{ end -}}
{{- with $i.resources }}{{ $_ := set $podSpec "containers" (list (dict "name" "istio-proxy" "resources" .)) }}{{ end -}}
{{- $deploymentSpec := dict "template" (dict "spec" $podSpec) -}}
{{- if not $i.autoscaling.enabled -}}
  {{- $_ := set $deploymentSpec "replicas" (int $i.replicas) -}}
{{- end -}}
deployment: |
  {{- toYaml (dict "spec" $deploymentSpec) | nindent 2 }}
{{- with (.service | default dict).annotations }}
service: |
  {{- toYaml (dict "metadata" (dict "annotations" .)) | nindent 2 }}
{{- end }}
{{- if $i.autoscaling.enabled }}
horizontalPodAutoscaler: |
  {{- toYaml (dict "spec" (dict "minReplicas" (int $i.autoscaling.minReplicas) "maxReplicas" (int $i.autoscaling.maxReplicas))) | nindent 2 }}
{{- end }}
{{- $minAvailable := $i.podDisruptionBudget.minAvailable }}
podDisruptionBudget: |
  {{- toYaml (dict "spec" (dict "minAvailable" (ternary $minAvailable (int $minAvailable) (kindIs "string" $minAvailable)))) | nindent 2 }}
{{- end -}}
