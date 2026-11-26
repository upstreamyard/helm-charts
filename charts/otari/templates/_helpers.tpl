{{- define "otari.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "otari.fullname" -}}
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

{{- define "otari.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "otari.selectorLabels" -}}
app.kubernetes.io/name: {{ include "otari.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Selector of the Otari server pods; the migration Job and test pods don't match it. */}}
{{- define "otari.serverSelectorLabels" -}}
{{ include "otari.selectorLabels" . }}
app.kubernetes.io/component: server
{{- end }}

{{- define "otari.labels" -}}
helm.sh/chart: {{ include "otari.chart" . }}
{{ include "otari.selectorLabels" . }}
app.kubernetes.io/version: {{ include "otari.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "otari.version" -}}
{{- default .Chart.AppVersion .Values.image.tag | trunc 63 }}
{{- end }}

{{- define "otari.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "otari.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "otari.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Label that lets a pod through the NetworkPolicy (the helm test pod has it). */}}
{{- define "otari.clientLabel" -}}
{{- printf "%s-client" (include "otari.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* "true" when Otari uses PostgreSQL (database.url or database.existingSecret). */}}
{{- define "otari.postgres" -}}
{{- if or .Values.database.url .Values.database.existingSecret }}true{{ end }}
{{- end }}

{{/* "true" when the migration Job runs (PostgreSQL only: the SQLite file lives on the pod's volume). */}}
{{- define "otari.migrationJob" -}}
{{- if and .Values.migrations.enabled (include "otari.postgres" .) }}true{{ end }}
{{- end }}

{{/* "true" when /data must be the PVC: the SQLite database or local file uploads live there. */}}
{{- define "otari.usePvc" -}}
{{- if and .Values.persistence.enabled (or (not (include "otari.postgres" .)) (eq .Values.files.backend "local")) }}true{{ end }}
{{- end }}

{{- define "otari.claimName" -}}
{{- default (printf "%s-data" (include "otari.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{/* "true" when more than one pod can run at once. */}}
{{- define "otari.scaled" -}}
{{- if or .Values.autoscaling.enabled (gt (int .Values.replicaCount) 1) }}true{{ end }}
{{- end }}

{{- define "otari.configMapName" -}}
{{- default (include "otari.fullname" .) .Values.existingConfigMap }}
{{- end }}

{{- define "otari.hasConfig" -}}
{{- if or .Values.config .Values.existingConfigMap }}true{{ end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "otari.validate" -}}
{{- $shared := has "ReadWriteMany" .Values.persistence.accessModes }}
{{- if include "otari.scaled" . }}
{{- if not (include "otari.postgres" .) }}
{{- fail "otari: more than one replica (replicaCount > 1 or autoscaling.enabled) needs PostgreSQL: set database.url or database.existingSecret. SQLite supports a single pod only" }}
{{- end }}
{{- if and (eq .Values.files.backend "local") (not (and .Values.persistence.enabled $shared)) }}
{{- fail "otari: more than one replica needs shared file storage: files.backend=s3, or persistence.accessModes [ReadWriteMany]" }}
{{- end }}
{{- end }}
{{- if not (has .Values.files.backend (list "local" "s3")) }}
{{- fail "otari: files.backend must be local or s3" }}
{{- end }}
{{- if and (eq .Values.files.backend "s3") (not .Values.files.s3.bucket) }}
{{- fail "otari: files.backend=s3 needs files.s3.bucket" }}
{{- end }}
{{- if and .Values.config (hasKey .Values.config "database_url") }}
{{- fail "otari: set the database in database.url or database.existingSecret, not config.database_url, so the migration Job uses it too" }}
{{- end }}
{{- if and .Values.config .Values.existingConfigMap }}
{{- fail "otari: set config or existingConfigMap, not both" }}
{{- end }}
{{- if and .Values.metrics.serviceMonitor.enabled (not .Values.metrics.enabled) }}
{{- fail "otari: metrics.serviceMonitor.enabled needs metrics.enabled" }}
{{- end }}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) }}
{{- fail "otari: httpRoute.enabled needs httpRoute.parentRefs (the Gateway to attach to)" }}
{{- end }}
{{- if le (int .Values.terminationGracePeriodSeconds) (int .Values.preStopSleepSeconds) }}
{{- fail "otari: terminationGracePeriodSeconds must be greater than preStopSleepSeconds" }}
{{- end }}
{{- range $name := list "providerAccountPepper" "providerUserIdentifierKey" }}
{{- $v := index $.Values.secrets $name }}
{{- if and $v (lt (len $v) 32) }}
{{- fail (printf "otari: secrets.%s must have at least 32 characters (Otari refuses to start otherwise)" $name) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
A generated key: the value already in the chart's Secret, else a new one. "fernet" makes a
Fernet key (32 random bytes, URL-safe base64), anything else 48 random letters and digits.
*/}}
{{- define "otari.generated" -}}
{{- $ := index . 0 }}
{{- $key := index . 1 }}
{{- $kind := index . 2 }}
{{- $existing := lookup "v1" "Secret" $.Release.Namespace (include "otari.fullname" $) }}
{{- $data := dict }}
{{- if $existing }}{{ $data = $existing.data | default dict }}{{ end }}
{{- if hasKey $data $key }}
{{- index $data $key | b64dec }}
{{- else if eq $kind "fernet" }}
{{- randBytes 32 | replace "+" "-" | replace "/" "_" }}
{{- else }}
{{- randAlphaNum 48 }}
{{- end }}
{{- end }}

{{/* Data of the chart's Secret. "hook" leaves only what the migration Job needs. */}}
{{- define "otari.secretData" -}}
{{- $ := index . 0 }}
{{- $hook := index . 1 }}
{{- if $.Values.database.url }}
database-url: {{ $.Values.database.url | b64enc | quote }}
{{- end }}
{{- if not $hook }}
{{- if not $.Values.secrets.existingSecret }}
master-key: {{ default (include "otari.generated" (list $ "master-key" "text")) $.Values.secrets.masterKey | b64enc | quote }}
secret-key: {{ default (include "otari.generated" (list $ "secret-key" "fernet")) $.Values.secrets.secretKey | b64enc | quote }}
provider-account-pepper: {{ default (include "otari.generated" (list $ "provider-account-pepper" "text")) $.Values.secrets.providerAccountPepper | b64enc | quote }}
provider-user-identifier-key: {{ default (include "otari.generated" (list $ "provider-user-identifier-key" "text")) $.Values.secrets.providerUserIdentifierKey | b64enc | quote }}
{{- end }}
{{- if $.Values.redis.url }}
redis-url: {{ $.Values.redis.url | b64enc | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/* secretKeyRef: (list chartSecretName existingSecret existingSecretKey chartKey [optional]) */}}
{{- define "otari.secretRef" -}}
{{- $existing := index . 1 }}
valueFrom:
  secretKeyRef:
    {{- if $existing }}
    name: {{ $existing }}
    key: {{ index . 2 }}
    {{- else }}
    name: {{ index . 0 }}
    key: {{ index . 3 }}
    {{- end }}
    {{- if and (gt (len .) 4) (index . 4) }}
    optional: true
    {{- end }}
{{- end }}

{{/* Database URL variable: (list $ secretName). */}}
{{- define "otari.databaseEnv" -}}
{{- $ := index . 0 }}
{{- if include "otari.postgres" $ }}
- name: OTARI_DATABASE_URL
  {{- include "otari.secretRef" (list (index . 1) $.Values.database.existingSecret $.Values.database.existingSecretKey "database-url") | nindent 2 }}
{{- end }}
{{- end }}

{{/* Environment of the Otari container. */}}
{{- define "otari.env" -}}
{{- $secret := include "otari.fullname" . }}
{{- $existing := .Values.secrets.existingSecret }}
{{- include "otari.databaseEnv" (list . $secret) }}
- name: OTARI_AUTO_MIGRATE
  value: {{ ternary "false" "true" (eq (include "otari.migrationJob" .) "true") | quote }}
- name: OTARI_MASTER_KEY
  {{- include "otari.secretRef" (list $secret $existing "master-key" "master-key") | nindent 2 }}
- name: OTARI_SECRET_KEY
  {{- include "otari.secretRef" (list $secret $existing "secret-key" "secret-key") | nindent 2 }}
- name: OTARI_PROVIDER_ACCOUNT_PEPPER
  {{- include "otari.secretRef" (list $secret $existing "provider-account-pepper" "provider-account-pepper" (ne $existing "")) | nindent 2 }}
- name: OTARI_PROVIDER_USER_IDENTIFIER_KEY
  {{- include "otari.secretRef" (list $secret $existing "provider-user-identifier-key" "provider-user-identifier-key" (ne $existing "")) | nindent 2 }}
- name: OTARI_BOOTSTRAP_API_KEY
  value: {{ .Values.bootstrapApiKey | quote }}
{{- if or .Values.redis.url .Values.redis.existingSecret }}
- name: OTARI_RATE_LIMIT_STORE
  value: redis
- name: OTARI_RATE_LIMIT_REDIS_URL
  {{- include "otari.secretRef" (list $secret .Values.redis.existingSecret .Values.redis.existingSecretKey "redis-url") | nindent 2 }}
{{- end }}
- name: OTARI_FILES_BACKEND
  value: {{ .Values.files.backend | quote }}
{{- if eq .Values.files.backend "local" }}
- name: OTARI_FILES_LOCAL_DIR
  value: /data/files
{{- else }}
- name: OTARI_FILES_S3_BUCKET
  value: {{ .Values.files.s3.bucket | quote }}
{{- with .Values.files.s3.endpointUrl }}
- name: OTARI_FILES_S3_ENDPOINT_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.files.s3.region }}
- name: OTARI_FILES_S3_REGION
  value: {{ . | quote }}
{{- end }}
{{- with .Values.files.s3.existingSecret }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.files.s3.accessKeyIdKey }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ $.Values.files.s3.secretAccessKeyKey }}
{{- end }}
{{- end }}
{{- if include "otari.hasConfig" . }}
- name: OTARI_CONFIG_PATH
  value: /etc/otari/config.yml
{{- end }}
{{- with .Values.publicBaseUrl }}
- name: OTARI_PUBLIC_BASE_URL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.forwardedAllowIps }}
- name: OTARI_FORWARDED_ALLOW_IPS
  value: {{ . | quote }}
{{- end }}
- name: OTARI_ENABLE_METRICS
  value: {{ .Values.metrics.enabled | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
