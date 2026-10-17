{{- define "docling-serve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "docling-serve.fullname" -}}
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

{{- define "docling-serve.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "docling-serve.selectorLabels" -}}
app.kubernetes.io/name: {{ include "docling-serve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "docling-serve.labels" -}}
helm.sh/chart: {{ include "docling-serve.chart" . }}
{{ include "docling-serve.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "docling-serve.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "docling-serve.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "docling-serve.image" -}}
{{- printf "%s:%s" .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) }}
{{- end }}

{{- define "docling-serve.workerImage" -}}
{{- printf "%s:%s" (default .Values.image.repository .Values.worker.image.repository) (default (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) .Values.worker.image.tag) }}
{{- end }}

{{- define "docling-serve.rq" -}}
{{- if eq .Values.engine.kind "rq" }}true{{ end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "docling-serve.validate" -}}
{{- if include "docling-serve.rq" . }}
{{- if and (not .Values.engine.rq.redisUrl) (not .Values.engine.rq.existingSecret) }}
{{- fail "docling-serve: engine.kind=rq requires engine.rq.redisUrl or engine.rq.existingSecret" }}
{{- end }}
{{- if and .Values.worker.autoscaling.enabled (not .Values.worker.autoscaling.redisAddress) }}
{{- fail "docling-serve: worker.autoscaling.enabled requires worker.autoscaling.redisAddress (host:port of Redis for KEDA)" }}
{{- end }}
{{- else }}
{{- if gt (int .Values.replicaCount) 1 }}
{{- fail "docling-serve: replicaCount > 1 requires engine.kind=rq (the local engine keeps tasks in the pod's memory)" }}
{{- end }}
{{- if .Values.autoscaling.enabled }}
{{- fail "docling-serve: autoscaling.enabled requires engine.kind=rq (the local engine keeps tasks in the pod's memory)" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "docling-serve.secretName" -}}
{{- include "docling-serve.fullname" . }}
{{- end }}

{{- define "docling-serve.apiKeySecretName" -}}
{{- default (include "docling-serve.secretName" .) .Values.apiKey.existingSecret }}
{{- end }}

{{- define "docling-serve.apiKeySecretKey" -}}
{{- if .Values.apiKey.existingSecret }}{{ .Values.apiKey.existingSecretKey }}{{ else }}api-key{{ end }}
{{- end }}

{{/* The API key: the value from values, the one already stored in the chart's Secret, or a new random one. */}}
{{- define "docling-serve.apiKey" -}}
{{- if .Values.apiKey.value }}
{{- .Values.apiKey.value }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "docling-serve.secretName" .) }}
{{- if and $existing $existing.data (hasKey $existing.data "api-key") }}
{{- index $existing.data "api-key" | b64dec }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{- define "docling-serve.createApiKey" -}}
{{- if and .Values.apiKey.enabled (not .Values.apiKey.existingSecret) }}true{{ end }}
{{- end }}

{{- define "docling-serve.createRedisUrl" -}}
{{- if and (include "docling-serve.rq" .) .Values.engine.rq.redisUrl (not .Values.engine.rq.existingSecret) }}true{{ end }}
{{- end }}

{{/* True when the chart creates its Secret. */}}
{{- define "docling-serve.createSecret" -}}
{{- if or (include "docling-serve.createApiKey" .) (include "docling-serve.createRedisUrl" .) }}true{{ end }}
{{- end }}

{{/* Inputs of the chart's Secret that come from values (not the generated key), for the checksum annotation. */}}
{{- define "docling-serve.secretChecksum" -}}
{{- list .Values.apiKey .Values.engine.rq.redisUrl | toJson | sha256sum }}
{{- end }}

{{/* Environment shared by API and worker pods. */}}
{{- define "docling-serve.commonEnv" -}}
- name: DOCLING_SERVE_ENG_KIND
  value: {{ .Values.engine.kind | quote }}
{{- if include "docling-serve.rq" . }}
- name: DOCLING_SERVE_ENG_RQ_REDIS_URL
  valueFrom:
    secretKeyRef:
      {{- if .Values.engine.rq.existingSecret }}
      name: {{ .Values.engine.rq.existingSecret }}
      key: {{ .Values.engine.rq.existingSecretKey }}
      {{- else }}
      name: {{ include "docling-serve.secretName" . }}
      key: redis-url
      {{- end }}
- name: DOCLING_SERVE_ENG_RQ_QUEUE_NAME
  value: {{ .Values.engine.rq.queueName | quote }}
{{- else }}
- name: DOCLING_SERVE_ENG_LOC_NUM_WORKERS
  value: {{ .Values.engine.local.numWorkers | quote }}
{{- end }}
{{- if .Values.models.download }}
- name: DOCLING_SERVE_ARTIFACTS_PATH
  value: /models
{{- end }}
- name: HOME
  value: /tmp
- name: HF_HOME
  value: /tmp/huggingface
- name: XDG_CACHE_HOME
  value: /tmp/.cache
- name: MPLCONFIGDIR
  value: /tmp/matplotlib
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "docling-serve.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- if .Values.models.download }}
- name: models
  mountPath: /models
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "docling-serve.volumes" -}}
- name: tmp
  emptyDir:
    sizeLimit: {{ .Values.tmpSizeLimit }}
{{- if .Values.models.download }}
- name: models
  {{- if .Values.models.existingClaim }}
  persistentVolumeClaim:
    claimName: {{ .Values.models.existingClaim }}
  {{- else }}
  emptyDir: {}
  {{- end }}
{{- end }}
{{- with .Values.extraVolumes }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Init container that copies the image's models to /models and downloads the extra ones.
Args: list $ image
*/}}
{{- define "docling-serve.modelsInit" -}}
{{- $ := index . 0 }}
{{- $image := index . 1 }}
{{- if $.Values.models.download }}
- name: models
  image: {{ $image }}
  imagePullPolicy: {{ $.Values.image.pullPolicy }}
  command:
    - sh
    - -c
    - |
      set -e
      cp -rn "$DOCLING_SERVE_ARTIFACTS_PATH"/. /models/
      exec docling-tools models download -o /models "$@"
    - models
    {{- range $.Values.models.download }}
    - {{ . | quote }}
    {{- end }}
  env:
    - name: HOME
      value: /tmp
    - name: HF_HOME
      value: /tmp/huggingface
  volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: models
      mountPath: /models
  securityContext:
    {{- toYaml $.Values.securityContext | nindent 4 }}
  {{- with $.Values.models.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
