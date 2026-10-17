{{- define "parse-server.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "parse-server.fullname" -}}
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

{{- define "parse-server.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "parse-server.selectorLabels" -}}
app.kubernetes.io/name: {{ include "parse-server.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "parse-server.labels" -}}
helm.sh/chart: {{ include "parse-server.chart" . }}
{{ include "parse-server.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "parse-server.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "parse-server.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "parse-server.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "parse-server.validate" -}}
{{- if not .Values.parse.appId }}
{{- fail "parse-server: set parse.appId (your app's application ID)" }}
{{- end }}
{{- if and (not .Values.parse.masterKey) (not .Values.parse.existingSecret) }}
{{- fail "parse-server: set parse.masterKey (e.g. `openssl rand -hex 32`) or parse.existingSecret" }}
{{- end }}
{{- if not .Values.parse.publicServerURL }}
{{- fail "parse-server: set parse.publicServerURL, the URL clients use, e.g. https://api.example.com/parse" }}
{{- end }}
{{- if and (not .Values.database.uri) (not .Values.database.existingSecret) }}
{{- fail "parse-server: set database.uri or database.existingSecret (MongoDB connection string)" }}
{{- end }}
{{- if and .Values.cloudCode.enabled (not .Values.cloudCode.main) (not .Values.cloudCode.existingConfigMap) }}
{{- fail "parse-server: cloudCode.enabled needs cloudCode.main or cloudCode.existingConfigMap" }}
{{- end }}
{{- end }}

{{/* Values for the Secret created by this chart. */}}
{{- define "parse-server.secretData" -}}
{{- if and .Values.parse.masterKey (not .Values.parse.existingSecret) }}
master-key: {{ .Values.parse.masterKey | b64enc | quote }}
{{- end }}
{{- if and .Values.database.uri (not .Values.database.existingSecret) }}
database-uri: {{ .Values.database.uri | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "parse-server.createSecret" -}}
{{- if include "parse-server.secretData" . | trim }}true{{ end }}
{{- end }}

{{- define "parse-server.cloudConfigMap" -}}
{{- default (printf "%s-cloud" (include "parse-server.fullname" .)) .Values.cloudCode.existingConfigMap }}
{{- end }}

{{/* Environment for the Parse Server container. */}}
{{- define "parse-server.env" -}}
- name: PORT
  value: "1337"
- name: PARSE_SERVER_APPLICATION_ID
  value: {{ .Values.parse.appId | quote }}
- name: PARSE_SERVER_MASTER_KEY
  valueFrom:
    secretKeyRef:
      name: {{ default (include "parse-server.fullname" .) .Values.parse.existingSecret }}
      key: {{ ternary .Values.parse.existingSecretKey "master-key" (not (empty .Values.parse.existingSecret)) }}
- name: PARSE_SERVER_DATABASE_URI
  valueFrom:
    secretKeyRef:
      name: {{ default (include "parse-server.fullname" .) .Values.database.existingSecret }}
      key: {{ ternary .Values.database.existingSecretKey "database-uri" (not (empty .Values.database.existingSecret)) }}
- name: PARSE_SERVER_MOUNT_PATH
  value: /parse
{{- /* Parse Server calls itself (Cloud Code, startup check) at serverURL. */}}
- name: PARSE_SERVER_URL
  value: http://127.0.0.1:1337/parse
- name: PARSE_PUBLIC_SERVER_URL
  value: {{ .Values.parse.publicServerURL | quote }}
{{- with .Values.parse.masterKeyIps }}
- name: PARSE_SERVER_MASTER_KEY_IPS
  value: {{ . | quote }}
{{- end }}
{{- /* Parse Server's CLI reads database options only as JSON in PARSE_SERVER_DATABASE_OPTIONS;
the per-option variable names in its option definitions are ignored. */}}
{{- $db := dict }}
{{- with .Values.parse.schemaCacheTtl }}{{ $_ := set $db "schemaCacheTtl" (int .) }}{{ end }}
{{- if .Values.parse.enableSchemaHooks }}{{ $_ := set $db "enableSchemaHooks" true }}{{ end }}
{{- if $db }}
- name: PARSE_SERVER_DATABASE_OPTIONS
  value: {{ toJson $db | quote }}
{{- end }}
- name: PARSE_SERVER_LOGS_FOLDER
  value: /parse-server/logs
{{- if .Values.cloudCode.enabled }}
- name: PARSE_SERVER_CLOUD
  value: /parse-server/cloud/{{ .Values.cloudCode.entrypoint }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
