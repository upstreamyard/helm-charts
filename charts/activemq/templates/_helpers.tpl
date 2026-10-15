{{- define "activemq.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "activemq.fullname" -}}
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

{{- define "activemq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "activemq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "activemq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "activemq.labels" -}}
helm.sh/chart: {{ include "activemq.chart" . }}
{{ include "activemq.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "activemq.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "activemq.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "activemq.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "activemq.headlessName" -}}
{{- printf "%s-headless" (include "activemq.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "activemq.secretName" -}}
{{- include "activemq.fullname" . }}
{{- end }}

{{/* True with more than one broker (master/slave). */}}
{{- define "activemq.ha" -}}
{{- if gt (int .Values.replicaCount) 1 }}true{{ end }}
{{- end }}

{{/* Port of each transport. */}}
{{- define "activemq.transportPort" -}}
{{- $ports := dict "openwire" 61616 "amqp" 5672 "stomp" 61613 "mqtt" 1883 "ws" 61614 }}
{{- index $ports . }}
{{- end }}

{{/* Port of the first transport: used by probes and helm test. */}}
{{- define "activemq.probePort" -}}
{{- include "activemq.transportPort" (first .Values.transports) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "activemq.validate" -}}
{{- if and (include "activemq.ha" .) (eq .Values.store.type "kahadb") (not .Values.persistence.existingClaim) }}
{{- fail "activemq: replicaCount > 1 needs a store all brokers share: set store.type=jdbc (with jdbc.url), or persistence.existingClaim with a ReadWriteMany volume. Separate KahaDB volumes would give independent brokers with split messages." }}
{{- end }}
{{- if eq .Values.store.type "jdbc" }}
{{- if not .Values.jdbc.url }}
{{- fail "activemq: store.type=jdbc needs jdbc.url, e.g. jdbc:postgresql://postgres:5432/activemq" }}
{{- end }}
{{- if not .Values.jdbc.user }}
{{- fail "activemq: store.type=jdbc needs jdbc.user" }}
{{- end }}
{{- if and (not .Values.jdbc.password) (not .Values.jdbc.existingSecret) }}
{{- fail "activemq: store.type=jdbc needs jdbc.password or jdbc.existingSecret" }}
{{- end }}
{{- end }}
{{- if and .Values.auth.appUser (eq .Values.auth.appUser .Values.auth.adminUser) }}
{{- fail "activemq: auth.appUser must differ from auth.adminUser" }}
{{- end }}
{{- if and .Values.metrics.serviceMonitor.enabled (not .Values.metrics.enabled) }}
{{- fail "activemq: metrics.serviceMonitor.enabled needs metrics.enabled=true" }}
{{- end }}
{{- end }}

{{/*
A password: the given value, else the one already in the chart's Secret (so upgrades keep
it), else a new random one. Args: list $ key value
*/}}
{{- define "activemq.password" -}}
{{- $ := index . 0 }}
{{- $key := index . 1 }}
{{- $value := index . 2 }}
{{- if $value }}
{{- $value }}
{{- else }}
{{- $existing := lookup "v1" "Secret" $.Release.Namespace (include "activemq.secretName" $) }}
{{- if and $existing $existing.data (hasKey $existing.data $key) }}
{{- index $existing.data $key | b64dec }}
{{- else }}
{{- randAlphaNum 24 }}
{{- end }}
{{- end }}
{{- end }}

{{/* True when the chart creates its Secret. */}}
{{- define "activemq.createSecret" -}}
{{- if or (not .Values.auth.existingSecret) (and (eq .Values.store.type "jdbc") .Values.jdbc.password (not .Values.jdbc.existingSecret)) }}true{{ end }}
{{- end }}

{{/* Failover URL listing every broker (OpenWire), for clients of a master/slave pair. */}}
{{- define "activemq.failoverUrl" -}}
{{- $urls := list }}
{{- range $i := until (int .Values.replicaCount) }}
{{- $urls = append $urls (printf "tcp://%s-%d.%s.%s.svc:61616" (include "activemq.fullname" $) $i (include "activemq.headlessName" $) $.Release.Namespace) }}
{{- end }}
{{- printf "failover:(%s)" (join "," $urls) }}
{{- end }}

{{/* URL clients use: the Service for one broker, a failover URL over all brokers otherwise. */}}
{{- define "activemq.clientUrl" -}}
{{- if include "activemq.ha" . }}
{{- include "activemq.failoverUrl" . }}
{{- else }}
{{- printf "tcp://%s.%s.svc:61616" (include "activemq.fullname" .) .Release.Namespace }}
{{- end }}
{{- end }}
