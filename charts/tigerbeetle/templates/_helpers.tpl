{{- define "tigerbeetle.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tigerbeetle.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 50 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 50 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 50 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "tigerbeetle.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tigerbeetle.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tigerbeetle.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "tigerbeetle.labels" -}}
helm.sh/chart: {{ include "tigerbeetle.chart" . }}
{{ include "tigerbeetle.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "tigerbeetle.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Name of the ConfigMap that marks a finished first install (see bootstrap.yaml). */}}
{{- define "tigerbeetle.bootstrappedName" -}}
{{- printf "%s-bootstrapped" (include "tigerbeetle.fullname" .) }}
{{- end }}

{{/* DNS name of replica $i's Service. Called with (list $ $i). */}}
{{- define "tigerbeetle.replicaHost" -}}
{{- $ := index . 0 }}
{{- printf "%s-%d.%s.svc.%s" (include "tigerbeetle.fullname" $) (index . 1) $.Release.Namespace $.Values.clusterDomain }}
{{- end }}

{{/*
Cluster ID: the value, else the one kept from an earlier install, else a new random one.
Only rendered into the cluster ConfigMap; pods and tests read it from there.
*/}}
{{- define "tigerbeetle.clusterId" -}}
{{- $cm := lookup "v1" "ConfigMap" .Release.Namespace (include "tigerbeetle.fullname" .) }}
{{- $existing := "" }}
{{- if $cm }}{{ $existing = index ($cm.data | default dict) "cluster-id" | default "" }}{{ end }}
{{- if .Values.cluster.id }}{{ .Values.cluster.id }}
{{- else if $existing }}{{ $existing }}
{{- else }}{{ printf "%d%s" (randInt 1 10) (randNumeric 29) }}{{ end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "tigerbeetle.validate" -}}
{{- $n := int .Values.replicaCount }}
{{- if or (lt $n 1) (gt $n 6) }}
{{- fail "tigerbeetle: replicaCount must be between 1 and 6" }}
{{- end }}
{{- if and .Values.replicaServices.clusterIPs (ne (len .Values.replicaServices.clusterIPs) $n) }}
{{- fail (printf "tigerbeetle: replicaServices.clusterIPs needs exactly one IP per replica (%d)" $n) }}
{{- end }}
{{- $cm := lookup "v1" "ConfigMap" .Release.Namespace (include "tigerbeetle.fullname" .) }}
{{- if and $cm $cm.data }}
{{- $oldCount := index $cm.data "replica-count" | default "" }}
{{- if and $oldCount (ne $oldCount (toString $n)) }}
{{- fail (printf "tigerbeetle: this cluster was formatted with replicaCount=%s. TigerBeetle can't change the replica count of an existing cluster" $oldCount) }}
{{- end }}
{{- $oldId := index $cm.data "cluster-id" | default "" }}
{{- if and .Values.cluster.id $oldId (ne $oldId .Values.cluster.id) }}
{{- fail (printf "tigerbeetle: cluster.id can't change after the first install (this cluster uses %s)" $oldId) }}
{{- end }}
{{- end }}
{{- end }}

{{/* Environment of the init container and the replica (read by tigerbeetle.sh). */}}
{{- define "tigerbeetle.env" -}}
- name: FULLNAME
  value: {{ include "tigerbeetle.fullname" . | quote }}
- name: NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: CLUSTER_DOMAIN
  value: {{ .Values.clusterDomain | quote }}
- name: PORT
  value: {{ .Values.port | quote }}
- name: REPLICA_COUNT
  value: {{ .Values.replicaCount | quote }}
- name: CLUSTER_ID
  valueFrom:
    configMapKeyRef:
      name: {{ include "tigerbeetle.fullname" . }}
      key: cluster-id
- name: ON_MISSING
  value: {{ .Values.dataFile.onMissing | quote }}
- name: CACHE_GRID
  value: {{ .Values.tigerbeetle.cacheGrid | quote }}
- name: DEVELOPMENT
  value: {{ .Values.tigerbeetle.development | quote }}
{{- end }}

{{- define "tigerbeetle.volumeMounts" -}}
- name: data
  mountPath: /data
- name: scripts
  mountPath: /scripts
  readOnly: true
- name: bootstrap
  mountPath: /bootstrap
  readOnly: true
{{- end }}
