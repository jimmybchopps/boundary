{{/*
The data of an Istio gateway's infrastructure ConfigMap (referenced by the Gateway's
spec.infrastructure.parametersRef): strategic-merge patches Istio applies to what it generates
for the Gateway. Istio 1.32 reads the keys deployment, service, serviceAccount,
horizontalPodAutoscaler, and podDisruptionBudget; the HPA and PDB exist only when their key is
present. Used for ingress gateways and egress waypoints (which have no service settings).

The deployment patch always sets three things Istio leaves out, so the pods meet the policy
chart without posture exceptions (README, "Gateway pod compliance"):
- the pod's seccomp profile, RuntimeDefault (the baked-in restrict-seccomp);
- automountServiceAccountToken: false (disallow-automount-service-account-token): the proxy
  never calls the Kubernetes API; it authenticates to istiod with the projected istio-token
  (audience istio-ca), and istiod sends it its certificates over SDS;
- a liveness probe on istio-proxy (require-probes), on the endpoint Istio's own startup and
  readiness probes use: pilot-agent's /healthz/ready on 15021, which checks Envoy itself.
  Istio's startup probe holds it back until the proxy first has its config, and it allows
  longer than readiness (2 minutes) before a restart.
Everything else Istio generates already meets the baked-in policies.

Usage: include "boundary.istio.infrastructure" $gateway   (a gateway from the model)
*/}}
{{- define "boundary.istio.infrastructure" -}}
{{- $i := .infrastructure -}}
{{- $podSpec := dict
      "securityContext" (dict "seccompProfile" (dict "type" "RuntimeDefault"))
      "automountServiceAccountToken" false -}}
{{- $proxy := dict "name" "istio-proxy" "livenessProbe" (dict
      "httpGet" (dict "path" "/healthz/ready" "port" 15021 "scheme" "HTTP")
      "periodSeconds" 15
      "timeoutSeconds" 3
      "failureThreshold" 8) -}}
{{- with $i.resources }}{{ $_ := set $proxy "resources" . }}{{ end -}}
{{- $_ := set $podSpec "containers" (list $proxy) -}}
{{- if $i.topologySpread -}}
  {{- $_ := set $podSpec "topologySpreadConstraints" (list (dict
        "maxSkew" 1
        "topologyKey" "kubernetes.io/hostname"
        "whenUnsatisfiable" "ScheduleAnyway"
        "labelSelector" (dict "matchLabels" (dict "gateway.networking.k8s.io/gateway-name" .name)))) -}}
{{- end -}}
{{- with $i.nodeSelector }}{{ $_ := set $podSpec "nodeSelector" . }}{{ end -}}
{{- with $i.tolerations }}{{ $_ := set $podSpec "tolerations" . }}{{ end -}}
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
