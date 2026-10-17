{{- define "falkordb.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "falkordb.fullname" -}}
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

{{- define "falkordb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "falkordb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "falkordb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "falkordb.labels" -}}
helm.sh/chart: {{ include "falkordb.chart" . }}
{{ include "falkordb.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "falkordb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "falkordb.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "falkordb.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "falkordb.headlessName" -}}
{{- printf "%s-headless" (include "falkordb.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "falkordb.secretName" -}}
{{- default (include "falkordb.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{- define "falkordb.secretKey" -}}
{{- ternary .Values.auth.existingSecretPasswordKey "password" (not (empty .Values.auth.existingSecret)) }}
{{- end }}

{{/* True with architecture=replication (primary, replicas and Sentinel). */}}
{{- define "falkordb.replication" -}}
{{- if eq .Values.architecture "replication" }}true{{ end }}
{{- end }}

{{- define "falkordb.replicas" -}}
{{- ternary .Values.replicaCount 1 (eq .Values.architecture "replication") }}
{{- end }}

{{/* Sentinel quorum: the given value, else a majority of the pods. */}}
{{- define "falkordb.quorum" -}}
{{- default (add1 (div (int .Values.replicaCount) 2)) .Values.sentinel.quorum }}
{{- end }}

{{/* FALKORDB_ARGS from the config map; null values are dropped. */}}
{{- define "falkordb.args" -}}
{{- $args := list }}
{{- range $key, $value := .Values.config }}
{{- if not (kindIs "invalid" $value) }}
{{- $args = append $args (printf "%s %v" $key $value) }}
{{- end }}
{{- end }}
{{- join " " $args }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "falkordb.validate" -}}
{{- if not (has .Values.architecture (list "standalone" "replication")) }}
{{- fail "falkordb: architecture must be standalone or replication" }}
{{- end }}
{{- if and (include "falkordb.replication" .) (lt (int .Values.replicaCount) 3) }}
{{- fail "falkordb: architecture=replication needs replicaCount >= 3. With 2 pods, the remaining Sentinel has no majority and can't promote the replica when a pod is gone." }}
{{- end }}
{{- if and (include "falkordb.replication" .) .Values.persistence.existingClaim }}
{{- fail "falkordb: persistence.existingClaim works only with architecture=standalone; replication gives each pod its own claim" }}
{{- end }}
{{- if and .Values.sentinel.quorum (gt (int .Values.sentinel.quorum) (int .Values.replicaCount)) }}
{{- fail "falkordb: sentinel.quorum can't be larger than replicaCount" }}
{{- end }}
{{- if and .Values.metrics.serviceMonitor.enabled (not .Values.metrics.enabled) }}
{{- fail "falkordb: metrics.serviceMonitor.enabled needs metrics.enabled=true" }}
{{- end }}
{{- end }}

{{/* The password: the given value, else the one already in the chart's Secret (so upgrades keep it), else a new random one. */}}
{{- define "falkordb.password" -}}
{{- if .Values.auth.password }}
{{- .Values.auth.password }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "falkordb.fullname" .) }}
{{- if and $existing $existing.data (hasKey $existing.data "password") }}
{{- index $existing.data "password" | b64dec }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{/* Password environment variable for redis-cli and the scripts. */}}
{{- define "falkordb.authEnv" -}}
{{- if .Values.auth.enabled }}
- name: REDISCLI_AUTH
  valueFrom:
    secretKeyRef:
      name: {{ include "falkordb.secretName" . }}
      key: {{ include "falkordb.secretKey" . }}
{{- end }}
{{- end }}

{{/* Environment shared by the FalkorDB and Sentinel containers. */}}
{{- define "falkordb.commonEnv" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: HEADLESS_DOMAIN
  value: {{ printf "%s.%s.svc.%s" (include "falkordb.headlessName" .) .Release.Namespace .Values.clusterDomain | quote }}
- name: STATEFULSET_NAME
  value: {{ include "falkordb.fullname" . | quote }}
- name: REPLICAS
  value: {{ include "falkordb.replicas" . | quote }}
- name: MASTER_SET
  value: {{ .Values.sentinel.masterSet | quote }}
{{ include "falkordb.authEnv" . }}
{{- end }}
