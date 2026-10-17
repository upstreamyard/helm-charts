{{- define "dolt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dolt.fullname" -}}
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

{{- define "dolt.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dolt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dolt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "dolt.labels" -}}
helm.sh/chart: {{ include "dolt.chart" . }}
{{ include "dolt.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "dolt.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dolt.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "dolt.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "dolt.headlessName" -}}
{{- printf "%s-headless" (include "dolt.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dolt.readName" -}}
{{- printf "%s-read" (include "dolt.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dolt.secretName" -}}
{{- default (include "dolt.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{- define "dolt.rootPasswordKey" -}}
{{- ternary .Values.auth.rootPasswordKey "root-password" (not (empty .Values.auth.existingSecret)) }}
{{- end }}

{{- define "dolt.userPasswordKey" -}}
{{- ternary .Values.auth.userPasswordKey "user-password" (not (empty .Values.auth.existingSecret)) }}
{{- end }}

{{/* True with more than one server (primary/standby cluster replication). */}}
{{- define "dolt.ha" -}}
{{- if gt (int .Values.replicaCount) 1 }}true{{ end }}
{{- end }}

{{/* DNS name of server i (stable, through the headless Service). Args: list $ i */}}
{{- define "dolt.podHost" -}}
{{- $ := index . 0 }}
{{- printf "%s-%d.%s.%s.svc" (include "dolt.fullname" $) (index . 1) (include "dolt.headlessName" $) $.Release.Namespace }}
{{- end }}

{{/*
Replication address of server i: its own ClusterIP Service. The IP stays the same when the
pod restarts; Dolt keeps dialing a restarted peer's old pod IP for ~30 s when given the
headless name. Args: list $ i
*/}}
{{- define "dolt.replicationHost" -}}
{{- $ := index . 0 }}
{{- printf "%s-%d-replication.%s.svc" (include "dolt.fullname" $) (index . 1) $.Release.Namespace }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "dolt.validate" -}}
{{- if and .Values.auth.username (not .Values.auth.database) }}
{{- fail "dolt: auth.username needs auth.database (the user gets all privileges on it)" }}
{{- end }}
{{- if and .Values.auth.username (eq .Values.auth.username "root") }}
{{- fail "dolt: auth.username is the application user and can't be root" }}
{{- end }}
{{- if and .Values.metrics.serviceMonitor.enabled (not .Values.metrics.enabled) }}
{{- fail "dolt: metrics.serviceMonitor.enabled needs metrics.enabled=true" }}
{{- end }}
{{- if and (include "dolt.ha" .) (not .Values.persistence.enabled) }}
{{- fail "dolt: replicaCount > 1 needs persistence.enabled=true. A server that comes back with an empty volume could start as the primary with no data" }}
{{- end }}
{{- if and .Values.config.listener (index .Values.config.listener "require_secure_transport") }}
{{- fail "dolt: config.listener.require_secure_transport isn't supported: the role labeler, the init Job and helm test connect without TLS. Clients can still use TLS (tls_cert, tls_key)" }}
{{- end }}
{{- range $k := list "cluster" "data_dir" }}
{{- if hasKey $.Values.config $k }}
{{- fail (printf "dolt: config.%s is set by the chart and can't be overridden" $k) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
A password: the given value, else the one already in the chart's Secret (so upgrades keep
it), else a new random one. Args: list $ key value
*/}}
{{- define "dolt.password" -}}
{{- $ := index . 0 }}
{{- $key := index . 1 }}
{{- $value := index . 2 }}
{{- if $value }}
{{- $value }}
{{- else }}
{{- $existing := lookup "v1" "Secret" $.Release.Namespace (include "dolt.fullname" $) }}
{{- if and $existing $existing.data (hasKey $existing.data $key) }}
{{- index $existing.data $key | b64dec }}
{{- else }}
{{- randAlphaNum 24 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
config.yaml of server i: the chart's defaults, then .Values.config, then the settings the
chart owns (data directory, listener address, metrics port, cluster). Args: list $ i
*/}}
{{- define "dolt.serverConfig" -}}
{{- $ := index . 0 }}
{{- $i := index . 1 }}
{{- $defaults := dict "log_level" $.Values.logLevel "listener" (dict "max_connections" 1000) }}
{{- $owned := dict "data_dir" "/var/lib/dolt" "listener" (dict "host" "0.0.0.0" "port" 3306) }}
{{- if $.Values.metrics.enabled }}
{{- $_ := set $owned "metrics" (dict "host" "0.0.0.0" "port" 11228) }}
{{- end }}
{{- if include "dolt.ha" $ }}
{{- $remotes := list }}
{{- range $j := until (int $.Values.replicaCount) }}
{{- if ne $j $i }}
{{- $remotes = append $remotes (dict "name" (printf "%s-%d" (include "dolt.fullname" $) $j) "remote_url_template" (printf "http://%s:50051/{database}" (include "dolt.replicationHost" (list $ $j)))) }}
{{- end }}
{{- end }}
{{- $_ := set $owned "cluster" (dict "standby_remotes" $remotes "bootstrap_role" (ternary "primary" "standby" (eq $i 0)) "bootstrap_epoch" 1 "remotesapi" (dict "port" 50051)) }}
{{- end }}
{{- mergeOverwrite $defaults (deepCopy $.Values.config) $owned | toYaml }}
{{- end }}
