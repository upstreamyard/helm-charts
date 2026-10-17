{{- define "kvrocks.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kvrocks.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 40 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 40 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "kvrocks.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "kvrocks.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kvrocks.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "kvrocks.labels" -}}
helm.sh/chart: {{ include "kvrocks.chart" . }}
{{ include "kvrocks.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "kvrocks.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "kvrocks.headless" -}}
{{- printf "%s-headless" (include "kvrocks.fullname" .) }}
{{- end }}

{{/* Majority of the members unless set. */}}
{{- define "kvrocks.quorum" -}}
{{- default (add (div (int .Values.replicaCount) 2) 1) .Values.sentinel.quorum }}
{{- end }}

{{/* Name of the Secret with the password. */}}
{{- define "kvrocks.secretName" -}}
{{- default (include "kvrocks.fullname" .) .Values.auth.existingSecret }}
{{- end }}

{{- define "kvrocks.secretKey" -}}
{{- if .Values.auth.existingSecret }}{{ .Values.auth.existingSecretKey }}{{ else }}password{{ end }}
{{- end }}

{{/* The value, else the password of an earlier install, else a new random one. */}}
{{- define "kvrocks.password" -}}
{{- if .Values.auth.password }}
{{- .Values.auth.password }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "kvrocks.fullname" .) }}
{{- if and $existing $existing.data (hasKey $existing.data "password") }}
{{- index $existing.data "password" | b64dec }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{/* Password environment variable for every container that talks to Kvrocks. */}}
{{- define "kvrocks.passwordEnv" -}}
{{- if .Values.auth.enabled }}
- name: KVROCKS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "kvrocks.secretName" . }}
      key: {{ include "kvrocks.secretKey" . }}
{{- end }}
{{- end }}

{{/* Settings in kvrocks.conf that the chart writes itself. */}}
{{- define "kvrocks.reservedConfig" -}}
bind port dir pidfile log-dir daemonize requirepass masterauth slaveof replicaof replica-announce-ip replica-announce-port cluster-enabled
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "kvrocks.validate" -}}
{{- $n := int .Values.replicaCount }}
{{- if .Values.sentinel.enabled }}
{{- if lt $n 3 }}
{{- fail "kvrocks: sentinel.enabled needs replicaCount of 3 or more (a majority of Sentinels must survive the loss of the master's pod)" }}
{{- end }}
{{- $q := int (include "kvrocks.quorum" .) }}
{{- if or (lt $q 1) (gt $q $n) }}
{{- fail (printf "kvrocks: sentinel.quorum must be between 1 and replicaCount (%d)" $n) }}
{{- end }}
{{- else if ne $n 1 }}
{{- fail "kvrocks: replicaCount above 1 needs sentinel.enabled=true (replicas without failover are not supported)" }}
{{- end }}
{{- $reserved := splitList " " (include "kvrocks.reservedConfig" .) }}
{{- range $k, $v := .Values.kvrocks.config }}
{{- if has $k $reserved }}
{{- fail (printf "kvrocks: kvrocks.config.%s is managed by the chart and can't be set" $k) }}
{{- end }}
{{- end }}
{{- end }}

{{/* Environment of the Kvrocks and Sentinel containers (read by the scripts). */}}
{{- define "kvrocks.scriptEnv" -}}
- name: FULLNAME
  value: {{ include "kvrocks.fullname" . | quote }}
- name: HEADLESS
  value: {{ include "kvrocks.headless" . | quote }}
- name: NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: CLUSTER_DOMAIN
  value: {{ .Values.clusterDomain | quote }}
- name: PORT
  value: {{ .Values.port | quote }}
- name: REPLICAS
  value: {{ .Values.replicaCount | quote }}
- name: SENTINEL
  value: {{ .Values.sentinel.enabled | quote }}
- name: SENTINEL_PORT
  value: {{ .Values.sentinel.port | quote }}
- name: MASTER_SET
  value: {{ .Values.sentinel.masterSet | quote }}
{{- include "kvrocks.passwordEnv" . }}
{{- end }}
