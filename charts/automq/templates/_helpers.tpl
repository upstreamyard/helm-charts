{{- define "automq.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "automq.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "automq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "automq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "automq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "automq.labels" -}}
helm.sh/chart: {{ include "automq.chart" . }}
{{ include "automq.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "automq.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "automq.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "automq.image" -}}
{{- printf "%s:%s" .Values.image.repository (default (printf "%s-kafka" .Chart.AppVersion) .Values.image.tag) }}
{{- end }}

{{- define "automq.headlessName" -}}
{{- printf "%s-headless" (include "automq.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "automq.secretName" -}}
{{- include "automq.fullname" . }}
{{- end }}

{{/* DNS suffix of the per-pod names: <pod>.<this>. */}}
{{- define "automq.podDomain" -}}
{{- printf "%s.%s.svc.%s" (include "automq.headlessName" .) .Release.Namespace .Values.clusterDomain }}
{{- end }}

{{/*
KRaft cluster ID: the given one, else a stable value from namespace and release name, so it
survives upgrades, `helm template` and GitOps tools alike. 21 hex characters plus "A" are a
valid base64url encoding of 16 bytes.
*/}}
{{- define "automq.clusterId" -}}
{{- if .Values.clusterId }}
{{- .Values.clusterId }}
{{- else }}
{{- printf "%s%s" (printf "automq/%s/%s" .Release.Namespace .Release.Name | sha256sum | trunc 21) "A" }}
{{- end }}
{{- end }}

{{/* Static quorum voters: <id>@<controller pod>:9093 */}}
{{- define "automq.quorumVoters" -}}
{{- $voters := list }}
{{- range $i := until (int .Values.controller.replicas) }}
{{- $voters = append $voters (printf "%d@%s-controller-%d.%s:9093" $i (include "automq.fullname" $) $i (include "automq.podDomain" $)) }}
{{- end }}
{{- join "," $voters }}
{{- end }}

{{/* S3 bucket URL in AutoMQ's format. Args: list $ id bucket */}}
{{- define "automq.bucketUrl" -}}
{{- $ := index . 0 }}
{{- $s3 := $.Values.s3 }}
{{- $params := list (printf "region=%s" $s3.region) }}
{{- with $s3.endpoint }}{{ $params = append $params (printf "endpoint=%s" .) }}{{ end }}
{{- if $s3.pathStyle }}{{ $params = append $params "pathStyle=true" }}{{ end }}
{{- printf "%d@s3://%s?%s" (index . 1) (index . 2) (join "&" $params) }}
{{- end }}

{{/* Number of nodes that act as brokers. */}}
{{- define "automq.brokerCount" -}}
{{- if .Values.controller.controllerOnly }}{{ .Values.broker.replicas }}{{ else }}{{ add .Values.controller.replicas .Values.broker.replicas }}{{ end }}
{{- end }}

{{/* Client bootstrap address. */}}
{{- define "automq.bootstrap" -}}
{{- printf "%s.%s.svc.%s:%d" (include "automq.fullname" .) .Release.Namespace .Values.clusterDomain (int .Values.service.port) }}
{{- end }}

{{/* A server property as the image's environment variable: . -> _, _ -> __, - -> ___ */}}
{{- define "automq.propertyEnv" -}}
{{- printf "KAFKA_%s" (. | replace "_" "__" | replace "-" "___" | replace "." "_" | upper) }}
{{- end }}

{{/* True when the chart creates its Secret. */}}
{{- define "automq.createSecret" -}}
{{- if or (and .Values.auth.enabled (not .Values.auth.existingSecret)) (and (eq .Values.s3.authType "static") (not .Values.s3.existingSecret)) }}true{{ end }}
{{- end }}

{{/*
A password: the given value, else the one already in the chart's Secret (so upgrades keep
it), else a new random one. Args: list $ key value
*/}}
{{- define "automq.password" -}}
{{- $ := index . 0 }}
{{- $key := index . 1 }}
{{- $value := index . 2 }}
{{- if $value }}
{{- $value }}
{{- else }}
{{- $existing := lookup "v1" "Secret" $.Release.Namespace (include "automq.secretName" $) }}
{{- if and $existing $existing.data (hasKey $existing.data $key) }}
{{- index $existing.data $key | b64dec }}
{{- else }}
{{- randAlphaNum 24 }}
{{- end }}
{{- end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "automq.validate" -}}
{{- if not (has (int .Values.controller.replicas) (list 1 3 5)) }}
{{- fail "automq: controller.replicas must be 1, 3 or 5 (a KRaft quorum needs an odd number of voters)" }}
{{- end }}
{{- if and .Values.controller.controllerOnly (lt (int .Values.broker.replicas) 1) }}
{{- fail "automq: controller.controllerOnly=true needs broker.replicas >= 1, otherwise no node serves clients" }}
{{- end }}
{{- if and (not .Values.s3.dataBucket) (not (hasKey .Values.config "s3.data.buckets")) }}
{{- fail "automq: set s3.dataBucket (AutoMQ stores all messages in S3-compatible object storage)" }}
{{- end }}
{{- if not (has .Values.s3.authType (list "static" "instance")) }}
{{- fail "automq: s3.authType must be static or instance" }}
{{- end }}
{{- if and (eq .Values.s3.authType "static") (not .Values.s3.existingSecret) (or (not .Values.s3.accessKey) (not .Values.s3.secretKey)) }}
{{- fail "automq: s3.authType=static needs s3.accessKey and s3.secretKey, or s3.existingSecret" }}
{{- end }}
{{- if .Values.auth.enabled }}
{{- if not .Values.auth.users }}
{{- fail "automq: auth.enabled=true needs at least one entry in auth.users" }}
{{- end }}
{{- range .Values.auth.users }}
{{- if not (regexMatch "^[A-Za-z0-9._-]+$" (toString .name)) }}
{{- fail (printf "automq: auth.users name %q may only use letters, digits, '.', '_' and '-'" (toString .name)) }}
{{- end }}
{{- if eq .name $.Values.auth.interBrokerUser }}
{{- fail "automq: auth.users must not contain auth.interBrokerUser" }}
{{- end }}
{{- if regexMatch "[\"\\\\]" (toString .password) }}
{{- fail (printf "automq: the password of %s must not contain \" or \\" .name) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and .Values.metrics.serviceMonitor.enabled (not .Values.metrics.enabled) }}
{{- fail "automq: metrics.serviceMonitor.enabled needs metrics.enabled=true" }}
{{- end }}
{{- end }}
