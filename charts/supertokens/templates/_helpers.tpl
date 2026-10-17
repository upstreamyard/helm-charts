{{- define "supertokens.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "supertokens.fullname" -}}
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

{{- define "supertokens.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "supertokens.selectorLabels" -}}
app.kubernetes.io/name: {{ include "supertokens.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "supertokens.labels" -}}
helm.sh/chart: {{ include "supertokens.chart" . }}
{{ include "supertokens.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "supertokens.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "supertokens.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "supertokens.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "supertokens.validate" -}}
{{- if and (not .Values.supertokens.apiKeys) (not .Values.supertokens.existingSecret) }}
{{- fail "supertokens: set supertokens.apiKeys (e.g. `openssl rand -hex 32`) or supertokens.existingSecret. Without an API key, anyone who can reach the core can manage your users." }}
{{- end }}
{{- if and (not .Values.database.uri) (not .Values.database.existingSecret) }}
{{- fail "supertokens: set database.uri or database.existingSecret (PostgreSQL connection URI)" }}
{{- end }}
{{- end }}

{{/* Values for the Secret created by this chart. */}}
{{- define "supertokens.secretData" -}}
{{- if and .Values.supertokens.apiKeys (not .Values.supertokens.existingSecret) }}
api-keys: {{ .Values.supertokens.apiKeys | b64enc | quote }}
{{- end }}
{{- if and .Values.database.uri (not .Values.database.existingSecret) }}
database-uri: {{ .Values.database.uri | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "supertokens.createSecret" -}}
{{- if include "supertokens.secretData" . | trim }}true{{ end }}
{{- end }}

{{/* Environment for the SuperTokens container. The core reads each config.yaml option from its upper-case name. */}}
{{- define "supertokens.env" -}}
- name: API_KEYS
  valueFrom:
    secretKeyRef:
      name: {{ default (include "supertokens.fullname" .) .Values.supertokens.existingSecret }}
      key: {{ ternary .Values.supertokens.existingSecretKey "api-keys" (not (empty .Values.supertokens.existingSecret)) }}
- name: POSTGRESQL_CONNECTION_URI
  valueFrom:
    secretKeyRef:
      name: {{ default (include "supertokens.fullname" .) .Values.database.existingSecret }}
      key: {{ ternary .Values.database.existingSecretKey "database-uri" (not (empty .Values.database.existingSecret)) }}
{{- with .Values.database.schema }}
- name: POSTGRESQL_TABLE_SCHEMA
  value: {{ . | quote }}
{{- end }}
{{- /* "null" sends logs to stdout instead of files in the installation directory. */}}
- name: INFO_LOG_PATH
  value: "null"
- name: ERROR_LOG_PATH
  value: "null"
{{- with .Values.supertokens.logLevel }}
- name: LOG_LEVEL
  value: {{ . | quote }}
{{- end }}
- name: DISABLE_TELEMETRY
  value: {{ (not .Values.supertokens.telemetry) | quote }}
- name: SCHEMA_CHECK_STRICT_MODE
  value: {{ .Values.supertokens.schemaCheckStrictMode | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
