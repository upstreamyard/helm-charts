{{- define "logto.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "logto.fullname" -}}
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

{{- define "logto.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "logto.selectorLabels" -}}
app.kubernetes.io/name: {{ include "logto.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "logto.labels" -}}
helm.sh/chart: {{ include "logto.chart" . }}
{{ include "logto.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "logto.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "logto.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "logto.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "logto.validate" -}}
{{- if and (not .Values.database.url) (not .Values.database.existingSecret) }}
{{- fail "logto: set database.url or database.existingSecret (PostgreSQL 14 or newer is required)" }}
{{- end }}
{{- end }}

{{- define "logto.redisEnabled" -}}
{{- if or .Values.redis.url .Values.redis.existingSecret }}true{{ end }}
{{- end }}

{{- define "logto.kekEnabled" -}}
{{- if or .Values.secretVault.kek .Values.secretVault.existingSecret }}true{{ end }}
{{- end }}

{{/* True when the chart has to create a Secret. */}}
{{- define "logto.createSecret" -}}
{{- if trim (include "logto.secretData" .) }}true{{ end }}
{{- end }}

{{- define "logto.secretData" -}}
{{- if and .Values.database.url (not .Values.database.existingSecret) }}
database-url: {{ .Values.database.url | b64enc | quote }}
{{- end }}
{{- if and .Values.redis.url (not .Values.redis.existingSecret) }}
redis-url: {{ .Values.redis.url | b64enc | quote }}
{{- end }}
{{- if and .Values.secretVault.kek (not .Values.secretVault.existingSecret) }}
secret-vault-kek: {{ .Values.secretVault.kek | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Secret-backed env vars. $secretName is the chart-created Secret to use
(the regular one for pods, the hook copy for the migration Job).
*/}}
{{- define "logto.secretEnv" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
- name: DB_URL
  valueFrom:
    secretKeyRef:
      {{- if $.Values.database.existingSecret }}
      name: {{ $.Values.database.existingSecret }}
      key: {{ $.Values.database.existingSecretKey }}
      {{- else }}
      name: {{ $secretName }}
      key: database-url
      {{- end }}
{{- if include "logto.redisEnabled" $ }}
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
{{- if include "logto.kekEnabled" $ }}
- name: SECRET_VAULT_KEK
  valueFrom:
    secretKeyRef:
      {{- if $.Values.secretVault.existingSecret }}
      name: {{ $.Values.secretVault.existingSecret }}
      key: {{ $.Values.secretVault.existingSecretKey }}
      {{- else }}
      name: {{ $secretName }}
      key: secret-vault-kek
      {{- end }}
{{- end }}
{{- end }}

{{/*
Logto copies its database alteration scripts into this folder at runtime. In the
image it is writable only for root's group, so the chart mounts an empty volume.
*/}}
{{- define "logto.alterationScriptsMount" -}}
- name: alteration-scripts
  mountPath: /etc/logto/packages/cli/alteration-scripts
{{- end }}
