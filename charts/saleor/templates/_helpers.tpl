{{- define "saleor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "saleor.fullname" -}}
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

{{- define "saleor.dashboardFullname" -}}
{{- printf "%s-dashboard" (include "saleor.fullname" . | trunc 53 | trimSuffix "-") }}
{{- end }}

{{- define "saleor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "saleor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "saleor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "saleor.labels" -}}
helm.sh/chart: {{ include "saleor.chart" . }}
{{ include "saleor.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "saleor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "saleor.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "saleor.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/*
Celery queue for the data-migration tasks that `migrate` queues. It is named after the image
tag, so workers of the previous version (still running while the migration Job runs) don't
take tasks they don't know and would discard.
*/}}
{{- define "saleor.migrationQueue" -}}
{{- printf "saleor-data-migrations-%s" (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Host of saleor.publicUrl, e.g. api.example.com. */}}
{{- define "saleor.publicHost" -}}
{{- (urlParse .Values.saleor.publicUrl).hostname }}
{{- end }}

{{- define "saleor.dashboardApiUrl" -}}
{{- default (printf "%s/graphql/" (trimSuffix "/" .Values.saleor.publicUrl)) .Values.dashboard.apiUrl }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "saleor.validate" -}}
{{- $url := .Values.saleor.publicUrl }}
{{- if not $url }}
{{- fail "saleor: set saleor.publicUrl (the public URL of the API, e.g. https://api.example.com/)" }}
{{- end }}
{{- $u := urlParse $url }}
{{- if or (not (has $u.scheme (list "http" "https"))) (not $u.host) (not (has $u.path (list "" "/"))) }}
{{- fail "saleor: saleor.publicUrl must be a URL with scheme and host only, e.g. https://api.example.com/ (Saleor ignores a path)" }}
{{- end }}
{{- if not .Values.saleor.allowedClientHosts }}
{{- fail "saleor: set saleor.allowedClientHosts (the hosts of your storefronts and the dashboard, e.g. [shop.example.com, dashboard.example.com])" }}
{{- end }}
{{- if and (not .Values.saleor.existingSecret) (or (not .Values.saleor.secretKey) (not .Values.saleor.rsaPrivateKey)) }}
{{- fail "saleor: set saleor.secretKey (e.g. `openssl rand -hex 32`) and saleor.rsaPrivateKey (e.g. `openssl genrsa 2048`), or saleor.existingSecret" }}
{{- end }}
{{- if and .Values.saleor.rsaPrivateKey (not (contains "PRIVATE KEY-----" .Values.saleor.rsaPrivateKey)) }}
{{- fail "saleor: saleor.rsaPrivateKey must be a PEM private key (-----BEGIN PRIVATE KEY----- or -----BEGIN RSA PRIVATE KEY-----)" }}
{{- end }}
{{- if and (not .Values.database.url) (not .Values.database.existingSecret) }}
{{- fail "saleor: set database.url (PostgreSQL) or database.existingSecret" }}
{{- end }}
{{- if and (not .Values.celery.brokerUrl) (not .Values.celery.existingSecret) }}
{{- fail "saleor: set celery.brokerUrl (e.g. redis://redis:6379/1) or celery.existingSecret. Saleor runs webhooks, search indexing and data migrations as background tasks" }}
{{- end }}
{{- if eq .Values.storage.type "s3" }}
{{- if or (not .Values.storage.s3.mediaBucket) (not .Values.storage.s3.privateBucket) }}
{{- fail "saleor: set storage.s3.mediaBucket and storage.s3.privateBucket (or storage.type=custom and configure GCS/Azure via extraEnv). The API and the worker share files through them" }}
{{- end }}
{{- if or (and .Values.storage.s3.accessKeyId (not .Values.storage.s3.secretAccessKey)) (and .Values.storage.s3.secretAccessKey (not .Values.storage.s3.accessKeyId)) }}
{{- fail "saleor: set both storage.s3.accessKeyId and storage.s3.secretAccessKey, or neither (to use the pod's cloud identity)" }}
{{- end }}
{{- end }}
{{- if and .Values.admin.email (not .Values.admin.password) (not .Values.admin.existingSecret) }}
{{- fail "saleor: admin.email needs admin.password or admin.existingSecret" }}
{{- end }}
{{- end }}

{{/* Values for the Secret created by this chart. */}}
{{- define "saleor.secretData" -}}
{{- if not .Values.saleor.existingSecret }}
secret-key: {{ .Values.saleor.secretKey | b64enc | quote }}
rsa-private-key: {{ .Values.saleor.rsaPrivateKey | b64enc | quote }}
{{- end }}
{{- if and .Values.database.url (not .Values.database.existingSecret) }}
database-url: {{ .Values.database.url | b64enc | quote }}
{{- end }}
{{- if and .Values.celery.brokerUrl (not .Values.celery.existingSecret) }}
broker-url: {{ .Values.celery.brokerUrl | b64enc | quote }}
{{- end }}
{{- if and .Values.cache.url (not .Values.cache.existingSecret) }}
cache-url: {{ .Values.cache.url | b64enc | quote }}
{{- end }}
{{- if and (eq .Values.storage.type "s3") .Values.storage.s3.accessKeyId (not .Values.storage.s3.existingSecret) }}
s3-access-key-id: {{ .Values.storage.s3.accessKeyId | b64enc | quote }}
s3-secret-access-key: {{ .Values.storage.s3.secretAccessKey | b64enc | quote }}
{{- end }}
{{- if and .Values.admin.email .Values.admin.password (not .Values.admin.existingSecret) }}
admin-password: {{ .Values.admin.password | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "saleor.createSecret" -}}
{{- if include "saleor.secretData" . | trim }}true{{ end }}
{{- end }}

{{- define "saleor.secretRef" -}}
{{- $secretName := index . 0 }}
{{- $existing := index . 1 }}
{{- $existingKey := index . 2 }}
{{- $key := index . 3 }}
valueFrom:
  secretKeyRef:
    {{- if $existing }}
    name: {{ $existing }}
    key: {{ $existingKey }}
    {{- else }}
    name: {{ $secretName }}
    key: {{ $key }}
    {{- end }}
{{- end }}

{{/*
Environment for all Saleor containers (API, worker, beat, migrations). $secretName is the
chart-created Secret to use (the regular one for pods, the hook copy for the migration Job).
*/}}
{{- define "saleor.env" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
{{- $fullname := include "saleor.fullname" $ }}
{{- $hosts := concat (list (include "saleor.publicHost" $) $fullname (printf "%s.%s.svc" $fullname $.Release.Namespace) (printf "%s.%s.svc.cluster.local" $fullname $.Release.Namespace)) $.Values.saleor.allowedHosts }}
- name: DEBUG
  value: "False"
- name: PUBLIC_URL
  value: {{ $.Values.saleor.publicUrl | quote }}
- name: ALLOWED_HOSTS
  value: {{ $hosts | uniq | join "," | quote }}
- name: ALLOWED_CLIENT_HOSTS
  value: {{ $.Values.saleor.allowedClientHosts | join "," | quote }}
- name: ALLOWED_GRAPHQL_ORIGINS
  value: {{ $.Values.saleor.allowedGraphqlOrigins | join "," | quote }}
- name: SEND_USAGE_TELEMETRY
  value: {{ ternary "True" "False" $.Values.saleor.usageTelemetry | quote }}
- name: PLAYGROUND_ENABLED
  value: {{ ternary "True" "False" $.Values.saleor.playground | quote }}
- name: SECRET_KEY
  {{- include "saleor.secretRef" (list $secretName $.Values.saleor.existingSecret $.Values.saleor.secretKeyKey "secret-key") | trim | nindent 2 }}
- name: RSA_PRIVATE_KEY
  {{- include "saleor.secretRef" (list $secretName $.Values.saleor.existingSecret $.Values.saleor.rsaPrivateKeyKey "rsa-private-key") | trim | nindent 2 }}
- name: DATABASE_URL
  {{- include "saleor.secretRef" (list $secretName $.Values.database.existingSecret $.Values.database.existingSecretKey "database-url") | trim | nindent 2 }}
- name: CELERY_BROKER_URL
  {{- include "saleor.secretRef" (list $secretName $.Values.celery.existingSecret $.Values.celery.existingSecretKey "broker-url") | trim | nindent 2 }}
{{- if or $.Values.cache.url $.Values.cache.existingSecret }}
- name: CACHE_URL
  {{- include "saleor.secretRef" (list $secretName $.Values.cache.existingSecret $.Values.cache.existingSecretKey "cache-url") | trim | nindent 2 }}
{{- end }}
{{- if eq $.Values.storage.type "s3" }}
{{- with $.Values.storage.s3 }}
- name: AWS_MEDIA_BUCKET_NAME
  value: {{ .mediaBucket | quote }}
- name: AWS_MEDIA_PRIVATE_BUCKET_NAME
  value: {{ .privateBucket | quote }}
{{- if .region }}
- name: AWS_S3_REGION_NAME
  value: {{ .region | quote }}
{{- end }}
{{- if .endpointUrl }}
- name: AWS_S3_ENDPOINT_URL
  value: {{ .endpointUrl | quote }}
{{- end }}
{{- if .customDomain }}
- name: AWS_MEDIA_CUSTOM_DOMAIN
  value: {{ .customDomain | quote }}
{{- end }}
- name: AWS_S3_URL_PROTOCOL
  value: {{ .urlProtocol | quote }}
{{- if or .accessKeyId .existingSecret }}
- name: AWS_ACCESS_KEY_ID
  {{- include "saleor.secretRef" (list $secretName .existingSecret .accessKeyIdKey "s3-access-key-id") | trim | nindent 2 }}
- name: AWS_SECRET_ACCESS_KEY
  {{- include "saleor.secretRef" (list $secretName .existingSecret .secretAccessKeyKey "s3-secret-access-key") | trim | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
{{- with $.Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Writable /tmp (the root filesystem is read-only) plus user mounts. */}}
{{- define "saleor.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "saleor.volumes" -}}
- name: tmp
  emptyDir: {}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Pod template annotations shared by the Saleor Deployments. */}}
{{- define "saleor.podAnnotations" -}}
{{- if include "saleor.createSecret" . }}
checksum/secret: {{ include "saleor.secretData" . | sha256sum }}
{{- end }}
{{- with .Values.podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Scheduling settings shared by all pods. */}}
{{- define "saleor.scheduling" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
