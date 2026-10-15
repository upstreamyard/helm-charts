{{- define "discourse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "discourse.fullname" -}}
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

{{- define "discourse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "discourse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "discourse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "discourse.labels" -}}
helm.sh/chart: {{ include "discourse.chart" . }}
{{ include "discourse.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "discourse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "discourse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "discourse.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* True when an enabled volume is ReadWriteOnce, i.e. can only be shared by pods on one node. */}}
{{- define "discourse.rwoVolumes" -}}
{{- range $name := list "uploads" "backups" }}
{{- $p := index $.Values.persistence $name }}
{{- if and $p.enabled (not $p.existingClaim) (has "ReadWriteOnce" $p.accessModes) }}true{{ end }}
{{- end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "discourse.validate" -}}
{{- if not .Values.discourse.hostname }}
{{- fail "discourse: set discourse.hostname (the public hostname, used in links and emails)" }}
{{- end }}
{{- if and (not .Values.discourse.secretKeyBase) (not .Values.discourse.existingSecret) }}
{{- fail "discourse: set discourse.secretKeyBase (e.g. `openssl rand -hex 64`) or discourse.existingSecret" }}
{{- end }}
{{- if not .Values.database.host }}
{{- fail "discourse: set database.host (PostgreSQL 18 with the pgvector extension is required)" }}
{{- end }}
{{- if and (not .Values.database.password) (not .Values.database.existingSecret) }}
{{- fail "discourse: set database.password or database.existingSecret" }}
{{- end }}
{{- if not .Values.redis.host }}
{{- fail "discourse: set redis.host (Redis 7 is required)" }}
{{- end }}
{{- if and (include "discourse.rwoVolumes" .) (or (gt (int .Values.replicaCount) 1) .Values.sidekiq.enabled) }}
{{- fail "discourse: replicaCount > 1 and sidekiq.enabled need the uploads and backups volumes on every pod. Use persistence.*.accessModes [ReadWriteMany], persistence.*.existingClaim, or disable persistence and store uploads in S3" }}
{{- end }}
{{- end }}

{{/* Values for the Secret created by this chart. */}}
{{- define "discourse.secretData" -}}
{{- if and .Values.discourse.secretKeyBase (not .Values.discourse.existingSecret) }}
secret-key-base: {{ .Values.discourse.secretKeyBase | b64enc | quote }}
{{- end }}
{{- if and .Values.database.password (not .Values.database.existingSecret) }}
database-password: {{ .Values.database.password | b64enc | quote }}
{{- end }}
{{- if and .Values.redis.password (not .Values.redis.existingSecret) }}
redis-password: {{ .Values.redis.password | b64enc | quote }}
{{- end }}
{{- if and .Values.smtp.password (not .Values.smtp.existingSecret) }}
smtp-password: {{ .Values.smtp.password | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "discourse.createSecret" -}}
{{- if include "discourse.secretData" . | trim }}true{{ end }}
{{- end }}

{{- define "discourse.secretRef" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
{{- $existing := index . 2 }}
{{- $existingKey := index . 3 }}
{{- $key := index . 4 }}
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
Environment for all Discourse containers. $secretName is the chart-created Secret to use
(the regular one for pods, the hook copy for the migration Job).
*/}}
{{- define "discourse.env" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
- name: DISCOURSE_HOSTNAME
  value: {{ $.Values.discourse.hostname | quote }}
- name: DISCOURSE_SECRET_KEY_BASE
  {{- include "discourse.secretRef" (list $ $secretName $.Values.discourse.existingSecret $.Values.discourse.existingSecretKey "secret-key-base") | trim | nindent 2 }}
- name: DISCOURSE_DB_HOST
  value: {{ $.Values.database.host | quote }}
- name: DISCOURSE_DB_PORT
  value: {{ $.Values.database.port | quote }}
- name: DISCOURSE_DB_NAME
  value: {{ $.Values.database.name | quote }}
- name: DISCOURSE_DB_USERNAME
  value: {{ $.Values.database.username | quote }}
- name: DISCOURSE_DB_PASSWORD
  {{- include "discourse.secretRef" (list $ $secretName $.Values.database.existingSecret $.Values.database.existingSecretKey "database-password") | trim | nindent 2 }}
- name: DISCOURSE_REDIS_HOST
  value: {{ $.Values.redis.host | quote }}
- name: DISCOURSE_REDIS_PORT
  value: {{ $.Values.redis.port | quote }}
- name: DISCOURSE_REDIS_DB
  value: {{ $.Values.redis.db | quote }}
{{- if or $.Values.redis.password $.Values.redis.existingSecret }}
- name: DISCOURSE_REDIS_PASSWORD
  {{- include "discourse.secretRef" (list $ $secretName $.Values.redis.existingSecret $.Values.redis.existingSecretKey "redis-password") | trim | nindent 2 }}
{{- end }}
{{- with $.Values.discourse.developerEmails }}
- name: DISCOURSE_DEVELOPER_EMAILS
  value: {{ . | quote }}
{{- end }}
{{- with $.Values.discourse.notificationEmail }}
- name: DISCOURSE_NOTIFICATION_EMAIL
  value: {{ . | quote }}
{{- end }}
{{- if $.Values.smtp.address }}
- name: DISCOURSE_SMTP_ADDRESS
  value: {{ $.Values.smtp.address | quote }}
- name: DISCOURSE_SMTP_PORT
  value: {{ $.Values.smtp.port | quote }}
- name: DISCOURSE_SMTP_ENABLE_START_TLS
  value: {{ $.Values.smtp.enableStartTls | quote }}
{{- with $.Values.smtp.username }}
- name: DISCOURSE_SMTP_USER_NAME
  value: {{ . | quote }}
{{- end }}
{{- if or $.Values.smtp.password $.Values.smtp.existingSecret }}
- name: DISCOURSE_SMTP_PASSWORD
  {{- include "discourse.secretRef" (list $ $secretName $.Values.smtp.existingSecret $.Values.smtp.existingSecretKey "smtp-password") | trim | nindent 2 }}
{{- end }}
{{- end }}
{{- with $.Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Uploads and backups mounts for web and Sidekiq pods. */}}
{{- define "discourse.volumeMounts" -}}
{{- if .Values.persistence.uploads.enabled }}
- name: uploads
  mountPath: /var/www/discourse/public/uploads
{{- end }}
{{- if .Values.persistence.backups.enabled }}
- name: backups
  mountPath: /var/www/discourse/public/backups
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "discourse.volumes" -}}
{{- range $name := list "uploads" "backups" }}
{{- $p := index $.Values.persistence $name }}
{{- if $p.enabled }}
- name: {{ $name }}
  persistentVolumeClaim:
    claimName: {{ default (printf "%s-%s" (include "discourse.fullname" $) $name) $p.existingClaim }}
{{- end }}
{{- end }}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Migration Job. Arguments (dict): root, name (suffix), hook (Helm hook events),
secret (chart-created Secret to read), skipPost (skip post-deployment migrations).
*/}}
{{- define "discourse.migrationJob" -}}
{{- $ := .root }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "discourse.fullname" $ }}-{{ .name }}
  labels:
    {{- include "discourse.labels" $ | nindent 4 }}
    app.kubernetes.io/component: migrations
  annotations:
    helm.sh/hook: {{ .hook }}
    helm.sh/hook-weight: "0"
    helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
spec:
  backoffLimit: {{ $.Values.migrations.backoffLimit }}
  activeDeadlineSeconds: {{ $.Values.migrations.activeDeadlineSeconds }}
  template:
    metadata:
      labels:
        {{- include "discourse.selectorLabels" $ | nindent 8 }}
        app.kubernetes.io/component: migrations
    spec:
      restartPolicy: Never
      {{- with $.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /* The chart's ServiceAccount does not exist yet during pre-install hooks. */}}
      automountServiceAccountToken: false
      securityContext:
        {{- toYaml $.Values.podSecurityContext | nindent 8 }}
      containers:
        - name: migrate
          image: {{ include "discourse.image" $ }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          args: ["migrate"]
          env:
            - name: SKIP_POST_DEPLOYMENT_MIGRATIONS
              value: {{ ternary "1" "0" .skipPost | quote }}
            {{- include "discourse.env" (list $ .secret) | trim | nindent 12 }}
          {{- with $.Values.extraEnvFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          securityContext:
            {{- toYaml $.Values.securityContext | nindent 12 }}
          {{- with $.Values.migrations.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      {{- with $.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
