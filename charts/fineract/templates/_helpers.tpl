{{- define "fineract.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fineract.fullname" -}}
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

{{/* Name of a component's resources, e.g. fineract-read. */}}
{{- define "fineract.componentName" -}}
{{- $ := index . 0 }}
{{- printf "%s-%s" (include "fineract.fullname" $ | trunc 55 | trimSuffix "-") (index . 1) }}
{{- end }}

{{- define "fineract.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "fineract.selectorLabels" -}}
app.kubernetes.io/name: {{ include "fineract.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "fineract.labels" -}}
helm.sh/chart: {{ include "fineract.chart" . }}
{{ include "fineract.selectorLabels" . }}
app.kubernetes.io/version: {{ include "fineract.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "fineract.version" -}}
{{- default .Chart.AppVersion .Values.image.tag | trunc 63 }}
{{- end }}

{{- define "fineract.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "fineract.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "fineract.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Database settings */}}
{{- define "fineract.dbPort" -}}
{{- if .Values.database.port }}{{ .Values.database.port }}{{ else if eq .Values.database.type "mariadb" }}3306{{ else }}5432{{ end }}
{{- end }}

{{- define "fineract.dbDriver" -}}
{{- if eq .Values.database.type "mariadb" }}org.mariadb.jdbc.Driver{{ else }}org.postgresql.Driver{{ end }}
{{- end }}

{{- define "fineract.jdbcUrl" -}}
{{- printf "jdbc:%s://%s:%s/%s" .Values.database.type .Values.database.host (include "fineract.dbPort" .) .Values.database.tenantsDatabase }}
{{- with .Values.database.parameters }}?{{ . }}{{ end }}
{{- end }}

{{/* TLS settings */}}
{{- define "fineract.tlsEnabled" -}}
{{- if ne .Values.tls.mode "disabled" }}true{{ end }}
{{- end }}

{{- define "fineract.port" -}}
{{- if include "fineract.tlsEnabled" . }}8443{{ else }}8080{{ end }}
{{- end }}

{{- define "fineract.portName" -}}
{{- if include "fineract.tlsEnabled" . }}https{{ else }}http{{ end }}
{{- end }}

{{- define "fineract.scheme" -}}
{{- if include "fineract.tlsEnabled" . }}HTTPS{{ else }}HTTP{{ end }}
{{- end }}

{{- define "fineract.tlsSecretName" -}}
{{- default (printf "%s-tls" (include "fineract.fullname" .)) .Values.tls.secretName }}
{{- end }}

{{/* Documents are shared between pods only on a ReadWriteMany volume. */}}
{{- define "fineract.sharedDocuments" -}}
{{- if and .Values.persistence.enabled (has "ReadWriteMany" .Values.persistence.accessModes) }}true{{ end }}
{{- end }}

{{- define "fineract.claimName" -}}
{{- default (printf "%s-documents" (include "fineract.fullname" .)) .Values.persistence.existingClaim }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "fineract.validate" -}}
{{- if not (has .Values.database.type (list "postgresql" "mariadb")) }}
{{- fail "fineract: database.type must be postgresql or mariadb" }}
{{- end }}
{{- if not .Values.database.host }}
{{- fail "fineract: set database.host. Both databases (database.tenantsDatabase and database.defaultTenantDatabase) must exist before the install" }}
{{- end }}
{{- if and (not .Values.database.password) (not .Values.database.existingSecret) }}
{{- fail "fineract: set database.password or database.existingSecret" }}
{{- end }}
{{- if and (not .Values.tenant.masterPassword) (not .Values.tenant.existingSecret) }}
{{- fail "fineract: set tenant.masterPassword or tenant.existingSecret. It encrypts the tenant's database password: keep it safe and never change it after the install" }}
{{- end }}
{{- if not .Values.tenant.timezone }}
{{- fail "fineract: tenant.timezone must not be empty, e.g. UTC" }}
{{- end }}
{{- if not (has .Values.tls.mode (list "generated" "secret" "disabled")) }}
{{- fail "fineract: tls.mode must be generated, secret or disabled" }}
{{- end }}
{{- if and (eq .Values.tls.mode "secret") (not .Values.tls.secretName) (not .Values.tls.certManager.enabled) }}
{{- fail "fineract: tls.mode secret needs tls.secretName (a kubernetes.io/tls Secret) or tls.certManager.enabled" }}
{{- end }}
{{- if and .Values.tls.certManager.enabled (ne .Values.tls.mode "secret") }}
{{- fail "fineract: tls.certManager.enabled needs tls.mode secret" }}
{{- end }}
{{- if and .Values.tls.certManager.enabled (not .Values.tls.certManager.issuerRef.name) }}
{{- fail "fineract: tls.certManager.enabled needs tls.certManager.issuerRef.name" }}
{{- end }}
{{- if lt (int .Values.replicaCount) 1 }}
{{- fail "fineract: replicaCount must be at least 1" }}
{{- end }}
{{- if and (gt (int .Values.replicaCount) 1) (not .Values.batch.enabled) }}
{{- fail "fineract: replicaCount > 1 needs batch.enabled=true, so that scheduled jobs run in one pod only" }}
{{- end }}
{{- $needShared := or (gt (int .Values.replicaCount) 1) .Values.reader.enabled }}
{{- if and $needShared .Values.persistence.enabled (not (include "fineract.sharedDocuments" .)) }}
{{- fail "fineract: replicaCount > 1 and reader.enabled need documents on shared storage: persistence.accessModes [ReadWriteMany], or persistence.enabled=false with S3 settings in extraEnv (FINERACT_CONTENT_S3_*)" }}
{{- end }}
{{- if .Values.admin.password }}
{{- include "fineract.checkAdminPassword" .Values.admin.password }}
{{- end }}
{{- end }}

{{/* Fineract 1.16's "strong" password policy, checked before it reaches Fineract. */}}
{{- define "fineract.checkAdminPassword" -}}
{{- $p := . }}
{{- $ok := and (ge (len $p) 12) (le (len $p) 50) (regexMatch "[A-Z]" $p) (regexMatch "[a-z]" $p) (regexMatch "[0-9]" $p) (regexMatch "[^A-Za-z0-9_\\s]" $p) (not (regexMatch "\\s" $p)) }}
{{- $prev := "" }}
{{- range $i := until (len $p) }}
{{- $c := substr $i (add1 $i | int) $p }}
{{- if eq $c $prev }}{{ $ok = false }}{{ end }}
{{- $prev = $c }}
{{- end }}
{{- if not $ok }}
{{- fail "fineract: admin.password must have 12-50 characters with upper and lower case, a digit and a special character, no spaces and no character twice in a row (Fineract's password policy)" }}
{{- end }}
{{- end }}

{{/*
A password that meets Fineract's "strong" policy: groups of upper case, lower case, digit and
special character, so no character can follow itself.
*/}}
{{- define "fineract.generatePassword" -}}
{{- $special := "!#%*+-=?@^" }}
{{- $out := "" }}
{{- range until 6 }}
{{- $i := randNumeric 1 | atoi }}
{{- $out = printf "%s%s%s%s%s" $out (randAlpha 1 | upper) (randAlpha 1 | lower) (randNumeric 1) (substr $i (add1 $i | int) $special) }}
{{- end }}
{{- $out }}
{{- end }}

{{/* Admin password: from values, else the one already in the chart's Secret, else a new one. */}}
{{- define "fineract.adminPassword" -}}
{{- if .Values.admin.password }}
{{- .Values.admin.password }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "fineract.fullname" .) }}
{{- $data := dict }}
{{- if $existing }}{{ $data = $existing.data | default dict }}{{ end }}
{{- if hasKey $data "admin-password" }}
{{- index $data "admin-password" | b64dec }}
{{- else }}
{{- include "fineract.generatePassword" . }}
{{- end }}
{{- end }}
{{- end }}

{{/* Data of the chart's Secret. "hook" leaves out what the migration Job doesn't need. */}}
{{- define "fineract.secretData" -}}
{{- $ := index . 0 }}
{{- $hook := index . 1 }}
{{- if not $.Values.database.existingSecret }}
database-password: {{ $.Values.database.password | b64enc | quote }}
{{- end }}
{{- if not $.Values.tenant.existingSecret }}
master-password: {{ $.Values.tenant.masterPassword | b64enc | quote }}
{{- end }}
{{- if and (not $hook) (not $.Values.admin.existingSecret) }}
admin-password: {{ include "fineract.adminPassword" $ | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "fineract.createSecret" -}}
{{- if include "fineract.secretData" (list . false) | trim }}true{{ end }}
{{- end }}

{{/* secretKeyRef: (list chartSecretName existingSecret existingSecretKey chartKey) */}}
{{- define "fineract.secretRef" -}}
{{- $chartSecret := index . 0 }}
{{- $existing := index . 1 }}
valueFrom:
  secretKeyRef:
    {{- if $existing }}
    name: {{ $existing }}
    key: {{ index . 2 }}
    {{- else }}
    name: {{ $chartSecret }}
    key: {{ index . 3 }}
    {{- end }}
{{- end }}

{{/*
Environment of a Fineract container: (list $ secretName role). Roles: all (write + batch in one
pod), write, read, batch, migrate.
*/}}
{{- define "fineract.env" -}}
{{- $ := index . 0 }}
{{- $secret := index . 1 }}
{{- $role := index . 2 }}
- name: FINERACT_HIKARI_DRIVER_SOURCE_CLASS_NAME
  value: {{ include "fineract.dbDriver" $ | quote }}
- name: FINERACT_HIKARI_JDBC_URL
  value: {{ include "fineract.jdbcUrl" $ | quote }}
- name: FINERACT_HIKARI_USERNAME
  value: {{ $.Values.database.username | quote }}
- name: FINERACT_HIKARI_PASSWORD
  {{- include "fineract.secretRef" (list $secret $.Values.database.existingSecret $.Values.database.existingSecretKey "database-password") | nindent 2 }}
- name: FINERACT_DEFAULT_TENANTDB_HOSTNAME
  value: {{ $.Values.database.host | quote }}
- name: FINERACT_DEFAULT_TENANTDB_PORT
  value: {{ include "fineract.dbPort" $ | quote }}
- name: FINERACT_DEFAULT_TENANTDB_NAME
  value: {{ $.Values.database.defaultTenantDatabase | quote }}
- name: FINERACT_DEFAULT_TENANTDB_UID
  value: {{ $.Values.database.username | quote }}
- name: FINERACT_DEFAULT_TENANTDB_PWD
  {{- include "fineract.secretRef" (list $secret $.Values.database.existingSecret $.Values.database.existingSecretKey "database-password") | nindent 2 }}
- name: FINERACT_DEFAULT_TENANTDB_CONN_PARAMS
  value: {{ $.Values.database.parameters | quote }}
- name: FINERACT_DEFAULT_TENANTDB_IDENTIFIER
  value: {{ $.Values.tenant.identifier | quote }}
- name: FINERACT_DEFAULT_TENANTDB_TIMEZONE
  value: {{ $.Values.tenant.timezone | quote }}
- name: FINERACT_DEFAULT_TENANTDB_MASTER_PASSWORD
  {{- include "fineract.secretRef" (list $secret $.Values.tenant.existingSecret $.Values.tenant.existingSecretKey "master-password") | nindent 2 }}
{{- if eq $role "migrate" }}
- name: SPRING_PROFILES_ACTIVE
  value: liquibase-only
{{- else if or $.Values.migrations.enabled (not (has $role (list "all" "write"))) }}
- name: FINERACT_LIQUIBASE_ENABLED
  value: "false"
{{- end }}
{{- if eq $role "write" }}
- name: FINERACT_MODE_BATCH_MANAGER_ENABLED
  value: "false"
- name: FINERACT_MODE_BATCH_WORKER_ENABLED
  value: "false"
{{- else if eq $role "read" }}
- name: FINERACT_MODE_WRITE_ENABLED
  value: "false"
- name: FINERACT_MODE_BATCH_MANAGER_ENABLED
  value: "false"
- name: FINERACT_MODE_BATCH_WORKER_ENABLED
  value: "false"
{{- else if eq $role "batch" }}
- name: FINERACT_MODE_READ_ENABLED
  value: "false"
- name: FINERACT_MODE_WRITE_ENABLED
  value: "false"
{{- end }}
{{- if has $role (list "all" "write") }}
- name: FINERACT_ADMIN_PASSWORD
  {{- include "fineract.secretRef" (list (include "fineract.fullname" $) $.Values.admin.existingSecret $.Values.admin.existingSecretKey "admin-password") | nindent 2 }}
{{- end }}
{{- if eq $.Values.tls.mode "disabled" }}
- name: FINERACT_SERVER_SSL_ENABLED
  value: "false"
{{- else if eq $.Values.tls.mode "secret" }}
- name: FINERACT_SERVER_SSL_CERTIFICATE
  value: /etc/fineract/tls/tls.crt
- name: FINERACT_SERVER_SSL_CERTIFICATE_PRIVATE_KEY
  value: /etc/fineract/tls/tls.key
{{- end }}
- name: FINERACT_LOGGING_JSON_ENABLED
  value: {{ $.Values.logging.json | quote }}
- name: FINERACT_LOGGING_LEVEL
  value: {{ $.Values.logging.level | quote }}
{{- with $.Values.javaOpts }}
- name: JAVA_OPTS
  value: {{ . | quote }}
{{- end }}
{{- with $.Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}
