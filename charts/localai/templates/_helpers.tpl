{{- define "localai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "localai.fullname" -}}
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

{{- define "localai.workerName" -}}
{{- printf "%s-worker" (include "localai.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "localai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "localai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "localai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}

{{- define "localai.labels" -}}
helm.sh/chart: {{ include "localai.chart" . }}
{{ include "localai.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "localai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "localai.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference: repository:tag, with "-<variant>" appended to the tag. Args: list repository tag variant appVersion */}}
{{- define "localai.imageRef" -}}
{{- $repository := index . 0 }}
{{- $tag := default (printf "v%s" (index . 3)) (index . 1) }}
{{- $variant := index . 2 }}
{{- if $variant }}
{{- printf "%s:%s-%s" $repository $tag $variant }}
{{- else }}
{{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{- define "localai.image" -}}
{{- include "localai.imageRef" (list .Values.image.repository .Values.image.tag .Values.image.variant .Chart.AppVersion) }}
{{- end }}

{{- define "localai.workerImage" -}}
{{- include "localai.imageRef" (list (default .Values.image.repository .Values.worker.image.repository) (default .Values.image.tag .Values.worker.image.tag) .Values.worker.image.variant .Chart.AppVersion) }}
{{- end }}

{{- define "localai.distributed" -}}
{{- if eq .Values.mode "distributed" }}true{{ end }}
{{- end }}

{{/* User accounts are on in distributed mode (LocalAI requires them) or with auth.enabled. */}}
{{- define "localai.authOn" -}}
{{- if or (include "localai.distributed" .) .Values.auth.enabled }}true{{ end }}
{{- end }}

{{- define "localai.databaseConfigured" -}}
{{- if or .Values.database.url .Values.database.existingSecret }}true{{ end }}
{{- end }}

{{- define "localai.rwx" -}}
{{- if has "ReadWriteMany" .Values.persistence.accessModes }}true{{ end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "localai.validate" -}}
{{- if include "localai.distributed" . }}
{{- if not (include "localai.databaseConfigured" .) }}
{{- fail "localai: mode=distributed requires PostgreSQL: set database.url or database.existingSecret" }}
{{- end }}
{{- if and .Values.database.url (not (regexMatch "^postgres(ql)?://" .Values.database.url)) }}
{{- fail "localai: mode=distributed requires a PostgreSQL database.url (postgresql://...); SQLite is not supported" }}
{{- end }}
{{- if and (not .Values.distributed.nats.url) (not .Values.distributed.nats.existingSecret) }}
{{- fail "localai: mode=distributed requires NATS: set distributed.nats.url or distributed.nats.existingSecret" }}
{{- end }}
{{- if and (gt (int .Values.replicaCount) 1) (or (not .Values.persistence.enabled) (and (not .Values.persistence.existingClaim) (not (include "localai.rwx" .)))) }}
{{- fail "localai: replicaCount > 1 requires a ReadWriteMany volume, because frontends share the models directory: set persistence.accessModes=[ReadWriteMany] or persistence.existingClaim (with persistence.enabled=true)" }}
{{- end }}
{{- else }}
{{- if gt (int .Values.replicaCount) 1 }}
{{- fail "localai: replicaCount > 1 requires mode=distributed (a standalone server keeps models, settings and state on its own volume)" }}
{{- end }}
{{- end }}
{{- if and .Values.auth.admin.email (not (include "localai.authOn" .)) }}
{{- fail "localai: auth.admin.email requires user accounts: set auth.enabled=true (or mode=distributed)" }}
{{- end }}
{{- end }}

{{- define "localai.secretName" -}}
{{- include "localai.fullname" . }}
{{- end }}

{{/* A secret value: from values, else the one already in the chart's Secret, else random. Args: list $ key value length */}}
{{- define "localai.secretValue" -}}
{{- $ := index . 0 }}
{{- $key := index . 1 }}
{{- $value := index . 2 }}
{{- if $value }}
{{- $value }}
{{- else }}
{{- $existing := lookup "v1" "Secret" $.Release.Namespace (include "localai.secretName" $) }}
{{- if and $existing $existing.data (hasKey $existing.data $key) }}
{{- index $existing.data $key | b64dec }}
{{- else }}
{{- randAlphaNum (index . 3) }}
{{- end }}
{{- end }}
{{- end }}

{{- define "localai.createApiKey" -}}
{{- if and .Values.apiKey.enabled (not .Values.apiKey.existingSecret) }}true{{ end }}
{{- end }}

{{- define "localai.createAuthSecrets" -}}
{{- if and (include "localai.authOn" .) (not .Values.auth.existingSecret) }}true{{ end }}
{{- end }}

{{- define "localai.createRegistrationToken" -}}
{{- if and (include "localai.distributed" .) (not .Values.distributed.existingSecret) }}true{{ end }}
{{- end }}

{{- define "localai.createDatabaseUrl" -}}
{{- if and (include "localai.authOn" .) .Values.database.url (not .Values.database.existingSecret) }}true{{ end }}
{{- end }}

{{- define "localai.createNatsUrl" -}}
{{- if and (include "localai.distributed" .) .Values.distributed.nats.url (not .Values.distributed.nats.existingSecret) }}true{{ end }}
{{- end }}

{{/* True when the chart creates its Secret. */}}
{{- define "localai.createSecret" -}}
{{- if or (include "localai.createApiKey" .) (include "localai.createAuthSecrets" .) (include "localai.createRegistrationToken" .) (include "localai.createDatabaseUrl" .) (include "localai.createNatsUrl" .) }}true{{ end }}
{{- end }}

{{/* Inputs of the chart's Secret that come from values (not generated ones), for the checksum annotation. */}}
{{- define "localai.secretChecksum" -}}
{{- list .Values.apiKey .Values.auth.hmacSecret .Values.auth.existingSecret .Values.database .Values.distributed.nats .Values.distributed.registrationToken .Values.distributed.existingSecret | toJson | sha256sum }}
{{- end }}

{{/* secretKeyRef for a value that is either in the chart's Secret or in an existing one. Args: list $ existingSecret existingKey chartKey */}}
{{- define "localai.secretKeyRef" -}}
{{- $ := index . 0 }}
secretKeyRef:
  {{- if index . 1 }}
  name: {{ index . 1 }}
  key: {{ index . 2 }}
  {{- else }}
  name: {{ include "localai.secretName" $ }}
  key: {{ index . 3 }}
  {{- end }}
{{- end }}

{{- define "localai.apiKeyEnv" -}}
- name: LOCALAI_API_KEY
  valueFrom:
    {{- include "localai.secretKeyRef" (list . .Values.apiKey.existingSecret .Values.apiKey.existingSecretKey "api-key") | nindent 4 }}
{{- end }}

{{- define "localai.adminPasswordEnv" -}}
- name: ADMIN_PASSWORD
  valueFrom:
    {{- include "localai.secretKeyRef" (list . .Values.auth.existingSecret "admin-password" "admin-password") | nindent 4 }}
{{- end }}

{{- define "localai.registrationTokenEnv" -}}
- name: LOCALAI_REGISTRATION_TOKEN
  valueFrom:
    {{- include "localai.secretKeyRef" (list . .Values.distributed.existingSecret .Values.distributed.existingSecretKey "registration-token") | nindent 4 }}
- name: LOCALAI_REGISTRATION_REQUIRE_AUTH
  value: "true"
- name: LOCALAI_NATS_URL
  valueFrom:
    {{- include "localai.secretKeyRef" (list . .Values.distributed.nats.existingSecret .Values.distributed.nats.existingSecretKey "nats-url") | nindent 4 }}
{{- end }}

{{/* Environment of the server pods (standalone server or distributed frontends). */}}
{{- define "localai.serverEnv" -}}
- name: LOCALAI_ADDRESS
  value: ":8080"
- name: LOCALAI_MODELS_PATH
  value: /models
- name: LOCALAI_BACKENDS_PATH
  value: /backends
- name: LOCALAI_CONFIG_DIR
  value: /configuration
- name: LOCALAI_DATA_PATH
  value: /data
- name: LOCALAI_DOWNLOAD_STAGING_PATH
  value: /downloading
- name: HOME
  value: /tmp
{{- if .Values.apiKey.enabled }}
{{ include "localai.apiKeyEnv" . }}
{{- end }}
{{- if .Values.baseUrl }}
- name: LOCALAI_BASE_URL
  value: {{ .Values.baseUrl | quote }}
{{- end }}
{{- if include "localai.authOn" . }}
- name: LOCALAI_AUTH
  value: "true"
- name: LOCALAI_REGISTRATION_MODE
  value: {{ .Values.auth.registrationMode | quote }}
- name: LOCALAI_AUTH_HMAC_SECRET
  valueFrom:
    {{- include "localai.secretKeyRef" (list . .Values.auth.existingSecret "hmac-secret" "hmac-secret") | nindent 4 }}
{{- with .Values.auth.admin.email }}
- name: LOCALAI_ADMIN_EMAIL
  value: {{ . | quote }}
{{- end }}
{{- if include "localai.databaseConfigured" . }}
- name: LOCALAI_AUTH_DATABASE_URL
  valueFrom:
    {{- include "localai.secretKeyRef" (list . .Values.database.existingSecret .Values.database.existingSecretKey "database-url") | nindent 4 }}
{{- end }}
{{- end }}
{{- if include "localai.distributed" . }}
- name: LOCALAI_DISTRIBUTED
  value: "true"
- name: LOCALAI_AUTO_APPROVE_NODES
  value: {{ .Values.distributed.autoApproveNodes | toString | quote }}
{{ include "localai.registrationTokenEnv" . }}
{{- end }}
{{- if .Values.models.configs }}
- name: LOCALAI_MODELS_CONFIG_FILE
  value: /etc/localai/models.yaml
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}


{{/* Worker labels as "k=v,k=v" for LOCALAI_NODE_LABELS. */}}
{{- define "localai.nodeLabels" -}}
{{- $pairs := list }}
{{- range $k, $v := . }}
{{- $pairs = append $pairs (printf "%s=%v" $k $v) }}
{{- end }}
{{- join "," $pairs }}
{{- end }}
