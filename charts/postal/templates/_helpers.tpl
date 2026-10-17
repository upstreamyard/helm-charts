{{- define "postal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "postal.fullname" -}}
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

{{/* Name of a component's resources, e.g. postal-web. */}}
{{- define "postal.componentName" -}}
{{- $ := index . 0 }}
{{- printf "%s-%s" (include "postal.fullname" $ | trunc 56 | trimSuffix "-") (index . 1) }}
{{- end }}

{{- define "postal.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "postal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postal.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "postal.labels" -}}
helm.sh/chart: {{ include "postal.chart" . }}
{{ include "postal.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "postal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "postal.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "postal.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "postal.smtpHostname" -}}
{{- default .Values.postal.webHostname .Values.postal.smtpHostname }}
{{- end }}

{{- define "postal.mxRecords" -}}
{{- default (list (include "postal.smtpHostname" .)) .Values.dns.mxRecords | join "," }}
{{- end }}

{{/* Ingress hosts; defaults to postal.webHostname. */}}
{{- define "postal.ingressHosts" -}}
{{- $default := list (dict "host" .Values.postal.webHostname "paths" (list (dict "path" "/" "pathType" "Prefix"))) }}
{{- toYaml (default $default .Values.ingress.hosts) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "postal.validate" -}}
{{- $host := .Values.postal.webHostname }}
{{- if not $host }}
{{- fail "postal: set postal.webHostname (the hostname of the web interface, e.g. postal.example.com)" }}
{{- end }}
{{- if or (contains "/" $host) (contains ":" $host) }}
{{- fail "postal: postal.webHostname must be a hostname only, e.g. postal.example.com (no scheme, port or path)" }}
{{- end }}
{{- if not (has .Values.postal.webProtocol (list "http" "https")) }}
{{- fail "postal: postal.webProtocol must be http or https" }}
{{- end }}
{{- if and (not .Values.postal.existingSecret) (or (not .Values.postal.secretKey) (not .Values.postal.signingKey)) }}
{{- fail "postal: set postal.secretKey (e.g. `openssl rand -hex 64`) and postal.signingKey (e.g. `openssl genrsa 2048`), or postal.existingSecret" }}
{{- end }}
{{- if and .Values.postal.signingKey (not (contains "PRIVATE KEY-----" .Values.postal.signingKey)) }}
{{- fail "postal: postal.signingKey must be a PEM private key (-----BEGIN PRIVATE KEY----- or -----BEGIN RSA PRIVATE KEY-----)" }}
{{- end }}
{{- if not .Values.database.host }}
{{- fail "postal: set database.host (MariaDB 10.6 or newer)" }}
{{- end }}
{{- if and (not .Values.database.password) (not .Values.database.existingSecret) }}
{{- fail "postal: set database.password or database.existingSecret" }}
{{- end }}
{{- if and .Values.smtp.tls.enabled (not .Values.smtp.tls.secretName) }}
{{- fail "postal: smtp.tls.enabled needs smtp.tls.secretName (a kubernetes.io/tls Secret for the SMTP hostname)" }}
{{- end }}
{{- if and .Values.admin.email (not .Values.admin.password) (not .Values.admin.existingSecret) }}
{{- fail "postal: admin.email needs admin.password or admin.existingSecret" }}
{{- end }}
{{- if and .Values.admin.email (not .Values.migrations.enabled) }}
{{- fail "postal: admin.email needs migrations.enabled (the migration Job creates the admin user)" }}
{{- end }}
{{- end }}

{{/* Values for the Secret created by this chart. */}}
{{- define "postal.secretData" -}}
{{- if not .Values.postal.existingSecret }}
secret-key: {{ .Values.postal.secretKey | b64enc | quote }}
signing-key: {{ .Values.postal.signingKey | b64enc | quote }}
{{- end }}
{{- if and .Values.database.password (not .Values.database.existingSecret) }}
database-password: {{ .Values.database.password | b64enc | quote }}
{{- end }}
{{- if and .Values.systemEmail.password (not .Values.systemEmail.existingSecret) }}
smtp-password: {{ .Values.systemEmail.password | b64enc | quote }}
{{- end }}
{{- if and .Values.admin.email .Values.admin.password (not .Values.admin.existingSecret) }}
admin-password: {{ .Values.admin.password | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "postal.createSecret" -}}
{{- if include "postal.secretData" . | trim }}true{{ end }}
{{- end }}

{{- define "postal.secretRef" -}}
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
Environment for all Postal containers. Every process gets the full configuration, so a value
changes the same way everywhere. $secretName is the chart-created Secret to use (the regular one
for pods, the hook copy for the migration Job).
*/}}
{{- define "postal.env" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
{{- $v := $.Values }}
{{- $host := $v.postal.webHostname }}
- name: POSTAL_WEB_HOSTNAME
  value: {{ $host | quote }}
- name: POSTAL_WEB_PROTOCOL
  value: {{ $v.postal.webProtocol | quote }}
- name: POSTAL_SMTP_HOSTNAME
  value: {{ include "postal.smtpHostname" $ | quote }}
- name: POSTAL_SIGNING_KEY_PATH
  value: /signing-key/signing.key
{{- with $v.postal.trustedProxies }}
- name: POSTAL_TRUSTED_PROXIES
  value: {{ join "," . | quote }}
{{- end }}
{{- with $v.postal.smtpRelays }}
- name: POSTAL_SMTP_RELAYS
  value: {{ join "," . | quote }}
{{- end }}
- name: RAILS_SECRET_KEY
  {{- include "postal.secretRef" (list $secretName $v.postal.existingSecret $v.postal.secretKeyKey "secret-key") | trim | nindent 2 }}
- name: MAIN_DB_HOST
  value: {{ $v.database.host | quote }}
- name: MAIN_DB_PORT
  value: {{ $v.database.port | quote }}
- name: MAIN_DB_USERNAME
  value: {{ $v.database.username | quote }}
- name: MAIN_DB_PASSWORD
  {{- include "postal.secretRef" (list $secretName $v.database.existingSecret $v.database.existingSecretKey "database-password") | trim | nindent 2 }}
- name: MAIN_DB_DATABASE
  value: {{ $v.database.name | quote }}
- name: MESSAGE_DB_HOST
  value: {{ $v.database.host | quote }}
- name: MESSAGE_DB_PORT
  value: {{ $v.database.port | quote }}
- name: MESSAGE_DB_USERNAME
  value: {{ $v.database.username | quote }}
- name: MESSAGE_DB_PASSWORD
  {{- include "postal.secretRef" (list $secretName $v.database.existingSecret $v.database.existingSecretKey "database-password") | trim | nindent 2 }}
- name: MESSAGE_DB_DATABASE_NAME_PREFIX
  value: {{ $v.database.messageDatabasePrefix | quote }}
- name: DNS_MX_RECORDS
  value: {{ include "postal.mxRecords" $ | quote }}
- name: DNS_SPF_INCLUDE
  value: {{ default (printf "spf.%s" $host) $v.dns.spfInclude | quote }}
- name: DNS_RETURN_PATH_DOMAIN
  value: {{ default (printf "rp.%s" $host) $v.dns.returnPathDomain | quote }}
- name: DNS_ROUTE_DOMAIN
  value: {{ default (printf "routes.%s" $host) $v.dns.routeDomain | quote }}
- name: DNS_TRACK_DOMAIN
  value: {{ default (printf "track.%s" $host) $v.dns.trackDomain | quote }}
- name: DNS_HELO_HOSTNAME
  value: {{ default (include "postal.smtpHostname" $) $v.dns.heloHostname | quote }}
- name: DNS_DKIM_IDENTIFIER
  value: {{ $v.dns.dkimIdentifier | quote }}
- name: SMTP_HOST
  value: {{ default (include "postal.componentName" (list $ "smtp")) $v.systemEmail.host | quote }}
- name: SMTP_PORT
  value: {{ $v.systemEmail.port | quote }}
{{- with $v.systemEmail.username }}
- name: SMTP_USERNAME
  value: {{ . | quote }}
{{- end }}
{{- if or $v.systemEmail.password $v.systemEmail.existingSecret }}
- name: SMTP_PASSWORD
  {{- include "postal.secretRef" (list $secretName $v.systemEmail.existingSecret $v.systemEmail.existingSecretKey "smtp-password") | trim | nindent 2 }}
{{- end }}
- name: SMTP_FROM_NAME
  value: {{ $v.systemEmail.fromName | quote }}
- name: SMTP_FROM_ADDRESS
  value: {{ default (printf "postal@%s" $host) $v.systemEmail.fromAddress | quote }}
- name: WEB_SERVER_DEFAULT_PORT
  value: "5000"
- name: WEB_SERVER_DEFAULT_BIND_ADDRESS
  value: "0.0.0.0"
- name: WEB_SERVER_MAX_THREADS
  value: {{ $v.web.maxThreads | quote }}
- name: WORKER_DEFAULT_HEALTH_SERVER_PORT
  value: "9090"
- name: WORKER_DEFAULT_HEALTH_SERVER_BIND_ADDRESS
  value: "0.0.0.0"
- name: WORKER_THREADS
  value: {{ $v.worker.threads | quote }}
- name: SMTP_SERVER_DEFAULT_PORT
  value: {{ $v.smtp.containerPort | quote }}
- name: SMTP_SERVER_DEFAULT_BIND_ADDRESS
  value: {{ $v.smtp.bindAddress | quote }}
- name: SMTP_SERVER_DEFAULT_HEALTH_SERVER_PORT
  value: "9091"
- name: SMTP_SERVER_DEFAULT_HEALTH_SERVER_BIND_ADDRESS
  value: "0.0.0.0"
- name: SMTP_SERVER_MAX_MESSAGE_SIZE
  value: {{ $v.smtp.maxMessageSize | quote }}
- name: SMTP_SERVER_PROXY_PROTOCOL
  value: {{ $v.smtp.proxyProtocol | quote }}
- name: SMTP_SERVER_TLS_ENABLED
  value: {{ $v.smtp.tls.enabled | quote }}
{{- if $v.smtp.tls.enabled }}
- name: SMTP_SERVER_TLS_CERTIFICATE_PATH
  value: /smtp-tls/tls.crt
- name: SMTP_SERVER_TLS_PRIVATE_KEY_PATH
  value: /smtp-tls/tls.key
{{- end }}
{{- /* Pods started before the migration Job finished wait for it instead of failing. */}}
- name: MIGRATION_WAITER_ENABLED
  value: "true"
{{- with $v.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Writable directories (the root filesystem is read-only), the signing key, TLS and user mounts. */}}
{{- define "postal.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
- name: app-tmp
  mountPath: /opt/postal/app/tmp
- name: signing-key
  mountPath: /signing-key
  readOnly: true
{{- if .Values.smtp.tls.enabled }}
- name: smtp-tls
  mountPath: /smtp-tls
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "postal.volumes" -}}
{{- $ := index . 0 }}
{{- $secretName := index . 1 }}
- name: tmp
  emptyDir: {}
- name: app-tmp
  emptyDir: {}
- name: signing-key
  secret:
    secretName: {{ default $secretName $.Values.postal.existingSecret }}
    items:
      - key: {{ ternary $.Values.postal.signingKeyKey "signing-key" (not (empty $.Values.postal.existingSecret)) }}
        path: signing.key
{{- if $.Values.smtp.tls.enabled }}
- name: smtp-tls
  secret:
    secretName: {{ $.Values.smtp.tls.secretName }}
{{- end }}
{{- with $.Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Pod template annotations shared by the Postal Deployments. */}}
{{- define "postal.podAnnotations" -}}
{{- if include "postal.createSecret" . }}
checksum/secret: {{ include "postal.secretData" . | sha256sum }}
{{- end }}
{{- with .Values.podAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Scheduling settings shared by all pods. */}}
{{- define "postal.scheduling" -}}
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

{{/*
An HTTP probe of the web server with the Host header set to postal.webHostname: the web server
answers 403 (blocked host) to any other Host, such as the pod IP the kubelet uses.
*/}}
{{- define "postal.webProbe" -}}
{{- $ := index . 0 }}
{{- with index . 1 }}
{{- $probe := deepCopy . }}
{{- if and $probe.httpGet (not $probe.httpGet.httpHeaders) }}
{{- $_ := set $probe.httpGet "httpHeaders" (list (dict "name" "Host" "value" $.Values.postal.webHostname)) }}
{{- end }}
{{- toYaml $probe }}
{{- end }}
{{- end }}

{{/* A probe as YAML, or nothing if it is empty (disabled). */}}
{{- define "postal.probe" -}}
{{- with . }}{{ toYaml . }}{{ end }}
{{- end }}
