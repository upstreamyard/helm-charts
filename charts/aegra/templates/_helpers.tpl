{{- define "aegra.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aegra.fullname" -}}
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

{{- define "aegra.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "aegra.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aegra.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "aegra.labels" -}}
helm.sh/chart: {{ include "aegra.chart" . }}
{{ include "aegra.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "aegra.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "aegra.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "aegra.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "aegra.validate" -}}
{{- if and (not .Values.database.url) (not .Values.database.existingSecret) }}
{{- fail "aegra: set database.url or database.existingSecret (PostgreSQL with pgvector is required)" }}
{{- end }}
{{- if and (gt (int .Values.replicaCount) 1) (not (include "aegra.redisEnabled" .)) }}
{{- fail "aegra: replicaCount > 1 requires redis.url or redis.existingSecret (Aegra needs Redis for multiple instances)" }}
{{- end }}
{{- end }}

{{- define "aegra.redisEnabled" -}}
{{- if or .Values.redis.url .Values.redis.existingSecret }}true{{ end }}
{{- end }}

{{/* True when the chart has to create a Secret for connection strings. */}}
{{- define "aegra.createSecret" -}}
{{- if or (and .Values.database.url (not .Values.database.existingSecret)) (and .Values.redis.url (not .Values.redis.existingSecret)) }}true{{ end }}
{{- end }}

{{- define "aegra.secretData" -}}
{{- if and .Values.database.url (not .Values.database.existingSecret) }}
database-url: {{ .Values.database.url | b64enc | quote }}
{{- end }}
{{- if and .Values.redis.url (not .Values.redis.existingSecret) }}
redis-url: {{ .Values.redis.url | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Connection env vars. $secretName is the chart-created Secret to use
(the regular one for pods, the hook copy for the migration Job).
*/}}
{{- define "aegra.connectionEnv" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- if $.Values.database.existingSecret }}
      name: {{ $.Values.database.existingSecret }}
      key: {{ $.Values.database.existingSecretKey }}
      {{- else }}
      name: {{ $secretName }}
      key: database-url
      {{- end }}
{{- if include "aegra.redisEnabled" $ }}
- name: REDIS_BROKER_ENABLED
  value: "true"
- name: REDIS_URL
  valueFrom:
    secretKeyRef:
      {{- if $.Values.redis.existingSecret }}
      name: {{ $.Values.redis.existingSecret }}
      key: {{ $.Values.redis.existingSecretKey }}
      {{- else }}
      name: {{ $secretName }}
      key: redis-url
      {{- end }}
{{- end }}
{{- end }}
