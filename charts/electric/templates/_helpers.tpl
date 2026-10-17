{{- define "electric.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "electric.fullname" -}}
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

{{- define "electric.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "electric.selectorLabels" -}}
app.kubernetes.io/name: {{ include "electric.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "electric.labels" -}}
helm.sh/chart: {{ include "electric.chart" . }}
{{ include "electric.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "electric.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "electric.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "electric.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "electric.validate" -}}
{{- if and (not .Values.electric.secret) (not .Values.electric.existingSecret) (not .Values.electric.insecure) }}
{{- fail "electric: set electric.secret (e.g. `openssl rand -hex 32`) or electric.existingSecret. Without a secret, anyone who can reach Electric can read your tables. For development only, set electric.insecure=true." }}
{{- end }}
{{- if and (not .Values.database.url) (not .Values.database.existingSecret) }}
{{- fail "electric: set database.url or database.existingSecret (PostgreSQL connection URL)" }}
{{- end }}
{{- if and (eq (include "electric.rolloutStrategy" .) "RollingUpdate") (not .Values.persistence.enabled) }}
{{- fail "electric: rolloutStrategy=RollingUpdate needs persistence.enabled=true with storage both pods can mount (ReadWriteMany)" }}
{{- end }}
{{- end }}

{{/* Recreate or RollingUpdate. RollingUpdate only works when old and new pod can mount the volume at the same time. */}}
{{- define "electric.rolloutStrategy" -}}
{{- if .Values.rolloutStrategy }}
{{- .Values.rolloutStrategy }}
{{- else if and .Values.persistence.enabled (has "ReadWriteMany" .Values.persistence.accessModes) }}
{{- "RollingUpdate" }}
{{- else }}
{{- "Recreate" }}
{{- end }}
{{- end }}

{{/* Readiness probe: the user's, or one that matches the rollout strategy. */}}
{{- define "electric.readinessProbe" -}}
{{- if .Values.readinessProbe }}
{{- toYaml .Values.readinessProbe }}
{{- else if eq (include "electric.rolloutStrategy" .) "RollingUpdate" }}
{{- /* Accepts 202: the new pod serves existing shapes read-only until the old one releases the lock. */}}
httpGet:
  path: /v1/health
  port: http
periodSeconds: 5
timeoutSeconds: 3
failureThreshold: 3
{{- else }}
{{- /* Ready only when active (200), not while starting or waiting for the lock (202). */}}
exec:
  command:
    - sh
    - -c
    - test "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://localhost:3000/v1/health)" = 200
periodSeconds: 5
timeoutSeconds: 3
failureThreshold: 3
{{- end }}
{{- end }}

{{/* Values for the Secret created by this chart. */}}
{{- define "electric.secretData" -}}
{{- if and .Values.electric.secret (not .Values.electric.existingSecret) }}
electric-secret: {{ .Values.electric.secret | b64enc | quote }}
{{- end }}
{{- if not .Values.database.existingSecret }}
{{- with .Values.database.url }}
database-url: {{ . | b64enc | quote }}
{{- end }}
{{- with .Values.database.pooledUrl }}
pooled-database-url: {{ . | b64enc | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "electric.createSecret" -}}
{{- if include "electric.secretData" . | trim }}true{{ end }}
{{- end }}

{{/* Environment for the Electric container. */}}
{{- define "electric.env" -}}
{{- $fullname := include "electric.fullname" . }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ default $fullname .Values.database.existingSecret }}
      key: {{ ternary .Values.database.existingSecretKey "database-url" (not (empty .Values.database.existingSecret)) }}
{{- if .Values.database.existingSecret }}
{{- with .Values.database.existingSecretPooledUrlKey }}
- name: ELECTRIC_POOLED_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $.Values.database.existingSecret }}
      key: {{ . }}
{{- end }}
{{- else if .Values.database.pooledUrl }}
- name: ELECTRIC_POOLED_DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ $fullname }}
      key: pooled-database-url
{{- end }}
{{- if or .Values.electric.secret .Values.electric.existingSecret }}
- name: ELECTRIC_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ default $fullname .Values.electric.existingSecret }}
      key: {{ ternary .Values.electric.existingSecretKey "electric-secret" (not (empty .Values.electric.existingSecret)) }}
{{- else }}
- name: ELECTRIC_INSECURE
  value: "true"
{{- end }}
- name: ELECTRIC_PORT
  value: "3000"
- name: ELECTRIC_STORAGE_DIR
  value: /var/lib/electric/data
{{- if eq (include "electric.rolloutStrategy" .) "RollingUpdate" }}
{{- /* Old and new pod share the SQLite shape database during a rollover. Electric requires this on network filesystems and recommends it for all shared storage. */}}
- name: ELECTRIC_SHAPE_DB_EXCLUSIVE_MODE
  value: "true"
{{- end }}
{{- if not .Values.persistence.enabled }}
{{- /* Shape data is lost on restart, so the replication slot must not outlive the pod either. */}}
- name: CLEANUP_REPLICATION_SLOTS_ON_SHUTDOWN
  value: "true"
- name: ELECTRIC_TEMPORARY_REPLICATION_SLOT_USE_RANDOM_NAME
  value: "true"
{{- end }}
{{- with .Values.electric.replicationStreamId }}
- name: ELECTRIC_REPLICATION_STREAM_ID
  value: {{ . | quote }}
{{- end }}
{{- with .Values.electric.logLevel }}
- name: ELECTRIC_LOG_LEVEL
  value: {{ . | quote }}
{{- end }}
- name: ELECTRIC_LOG_COLORS
  value: "false"
{{- if .Values.metrics.enabled }}
- name: ELECTRIC_PROMETHEUS_PORT
  value: {{ .Values.metrics.port | quote }}
{{- end }}
{{- /* The release start script writes its runtime config here; the image's default is on the read-only root filesystem. */}}
- name: RELEASE_TMP
  value: /tmp
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
