{{- define "xxl-job.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "xxl-job.fullname" -}}
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

{{- define "xxl-job.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "xxl-job.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xxl-job.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "xxl-job.labels" -}}
helm.sh/chart: {{ include "xxl-job.chart" . }}
{{ include "xxl-job.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "xxl-job.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "xxl-job.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "xxl-job.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Context path without a trailing slash ("" for "/"), for building URLs. */}}
{{- define "xxl-job.basePath" -}}
{{- trimSuffix "/" .Values.contextPath }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "xxl-job.validate" -}}
{{- if not .Values.database.host }}
{{- fail "xxl-job: set database.host (MySQL is required)" }}
{{- end }}
{{- if not .Values.database.username }}
{{- fail "xxl-job: set database.username" }}
{{- end }}
{{- if and (not .Values.database.password) (not .Values.database.existingSecret) }}
{{- fail "xxl-job: set database.password or database.existingSecret" }}
{{- end }}
{{- if not (regexMatch "^/([A-Za-z0-9._-]+/?)*$" .Values.contextPath) }}
{{- fail "xxl-job: contextPath must start with / and contain only letters, digits, '.', '_', '-' and '/'" }}
{{- end }}
{{- end }}

{{- define "xxl-job.jdbcUrl" -}}
{{- $params := printf "useUnicode=true&characterEncoding=UTF-8&serverTimezone=%s" .Values.timezone }}
{{- with .Values.database.extraParams }}{{ $params = printf "%s&%s" $params . }}{{ end }}
{{- printf "jdbc:mysql://%s:%v/%s?%s" .Values.database.host .Values.database.port .Values.database.name $params }}
{{- end }}

{{/* True when the chart stores the admin password (only used by the setup Job). */}}
{{- define "xxl-job.chartAdminPassword" -}}
{{- if and .Values.schemaSetup.enabled (not .Values.admin.existingSecret) }}true{{ end }}
{{- end }}

{{/*
Admin password: the value, else the one kept in the chart's Secret from an earlier
install, else a random one. The random one is generated once per render and kept in
.Values, so the Secret and its hook copy get the same password.
*/}}
{{- define "xxl-job.adminPassword" -}}
{{- if .Values.admin.password }}
{{- .Values.admin.password }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "xxl-job.fullname" .) }}
{{- $existingData := dig "data" "admin-password" "" ($existing | default dict) }}
{{- if $existingData }}
{{- $existingData | b64dec }}
{{- else }}
{{- if not (hasKey .Values.admin "generatedPassword") }}
{{- $_ := set .Values.admin "generatedPassword" (randAlphaNum 24) }}
{{- end }}
{{- .Values.admin.generatedPassword }}
{{- end }}
{{- end }}
{{- end }}

{{/* True when the chart has to create a Secret. */}}
{{- define "xxl-job.createSecret" -}}
{{- if trim (include "xxl-job.secretData" .) }}true{{ end }}
{{- end }}

{{- define "xxl-job.secretData" -}}
{{- if not .Values.database.existingSecret }}
db-password: {{ .Values.database.password | b64enc | quote }}
{{- end }}
{{- if include "xxl-job.chartAdminPassword" . }}
admin-password: {{ include "xxl-job.adminPassword" . | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Database password env var. $secretName is the chart-created Secret to use
(the regular one for pods, the hook copy for the setup Job).
*/}}
{{- define "xxl-job.dbPasswordEnv" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
{{- $envName := index . 2 }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      {{- if $.Values.database.existingSecret }}
      name: {{ $.Values.database.existingSecret }}
      key: {{ $.Values.database.existingSecretKey }}
      {{- else }}
      name: {{ $secretName }}
      key: db-password
      {{- end }}
{{- end }}
