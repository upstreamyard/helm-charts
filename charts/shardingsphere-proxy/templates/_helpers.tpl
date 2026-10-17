{{- define "shardingsphere-proxy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "shardingsphere-proxy.fullname" -}}
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

{{- define "shardingsphere-proxy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "shardingsphere-proxy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "shardingsphere-proxy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "shardingsphere-proxy.labels" -}}
helm.sh/chart: {{ include "shardingsphere-proxy.chart" . }}
{{ include "shardingsphere-proxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "shardingsphere-proxy.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "shardingsphere-proxy.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "shardingsphere-proxy.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "shardingsphere-proxy.configSecret" -}}
{{- default (include "shardingsphere-proxy.fullname" .) .Values.existingSecret }}
{{- end }}

{{- define "shardingsphere-proxy.namespace" -}}
{{- default (include "shardingsphere-proxy.fullname" .) .Values.cluster.namespace }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "shardingsphere-proxy.validate" -}}
{{- if not .Values.existingSecret }}
{{- if not .Values.users }}
{{- fail "shardingsphere-proxy: set users (or existingSecret). Without users, ShardingSphere accepts root/root as admin from any host." }}
{{- end }}
{{- range .Values.users }}
{{- if or (not .user) (not .password) }}
{{- fail "shardingsphere-proxy: every entry in users needs user (name@host) and password" }}
{{- end }}
{{- end }}
{{- if not (has .Values.mode (list "Standalone" "Cluster")) }}
{{- fail "shardingsphere-proxy: mode must be Standalone or Cluster" }}
{{- end }}
{{- if and (eq .Values.mode "Cluster") (not .Values.cluster.zookeeper.serverLists) }}
{{- fail "shardingsphere-proxy: mode Cluster needs cluster.zookeeper.serverLists" }}
{{- end }}
{{- if and (gt (int .Values.replicaCount) 1) (ne .Values.mode "Cluster") }}
{{- fail "shardingsphere-proxy: replicaCount > 1 needs mode Cluster (with ZooKeeper), so all pods share one configuration" }}
{{- end }}
{{- end }}
{{- end }}

{{/* global.yaml, built from the values. */}}
{{- define "shardingsphere-proxy.globalYaml" -}}
{{- $global := dict "authority" (dict "users" .Values.users "privilege" .Values.privilege) }}
{{- if eq .Values.mode "Cluster" }}
{{- $props := merge (dict "namespace" (include "shardingsphere-proxy.namespace" .) "server-lists" .Values.cluster.zookeeper.serverLists) .Values.cluster.props }}
{{- $_ := set $global "mode" (dict "type" "Cluster" "repository" (dict "type" "ZooKeeper" "props" $props)) }}
{{- else }}
{{- $_ := set $global "mode" (dict "type" "Standalone" "repository" (dict "type" "JDBC")) }}
{{- end }}
{{- with .Values.props }}
{{- $_ := set $global "props" . }}
{{- end }}
{{- toYaml (merge $global .Values.globalConfig) }}
{{- end }}

{{/* Data of the config Secret: global.yaml plus one database-<name>.yaml per logical database. */}}
{{- define "shardingsphere-proxy.secretData" -}}
global.yaml: {{ include "shardingsphere-proxy.globalYaml" . | b64enc | quote }}
{{- range $name, $content := .Values.databases }}
database-{{ $name }}.yaml: {{ printf "databaseName: %s\n\n%s" $name $content | b64enc | quote }}
{{- end }}
{{- end }}
