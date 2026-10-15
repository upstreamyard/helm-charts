{{- define "cube.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "cube.fullname" -}}
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

{{- define "cube.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "cube.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cube.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "cube.labels" -}}
helm.sh/chart: {{ include "cube.chart" . }}
{{ include "cube.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "cube.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cube.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Cube's image tags start with "v". */}}
{{- define "cube.image" -}}
{{- printf "%s:%s" .Values.image.repository (default (printf "v%s" .Chart.AppVersion) .Values.image.tag) }}
{{- end }}

{{/* Cube Store has separate tags per platform: v1.2.3, v1.2.3-arm64v8, v1.2.3-non-avx. */}}
{{- define "cube.cubestoreImage" -}}
{{- $tag := default (printf "v%s" .Chart.AppVersion) .Values.cubestore.image.tag }}
{{- with .Values.cubestore.image.variant }}{{ $tag = printf "%s-%s" $tag . }}{{ end }}
{{- printf "%s:%s" .Values.cubestore.image.repository $tag }}
{{- end }}

{{- define "cube.routerName" -}}{{ include "cube.fullname" . }}-cubestore-router{{- end }}
{{- define "cube.workerName" -}}{{ include "cube.fullname" . }}-cubestore-worker{{- end }}
{{- define "cube.workerHeadless" -}}{{ include "cube.fullname" . }}-cubestore-worker-headless{{- end }}
{{- define "cube.modelConfigMap" -}}{{ default (printf "%s-model" (include "cube.fullname" .)) .Values.model.existingConfigMap }}{{- end }}
{{- define "cube.sharedClaim" -}}{{ default (printf "%s-cubestore-shared" (include "cube.fullname" .)) .Values.cubestore.storage.sharedVolume.existingClaim }}{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "cube.validate" -}}
{{- if and (not .Values.apiSecret.value) (not .Values.apiSecret.existingSecret) }}
{{- fail "cube: set apiSecret.value or apiSecret.existingSecret (Cube signs API tokens with it)" }}
{{- end }}
{{- if not .Values.datasource.type }}
{{- fail "cube: set datasource.type, e.g. postgres" }}
{{- end }}
{{- if and (not .Values.model.files) (not .Values.model.existingConfigMap) }}
{{- fail "cube: set model.files or model.existingConfigMap (Cube needs a data model)" }}
{{- end }}
{{- if .Values.cubestore.enabled }}
{{- $t := .Values.cubestore.storage.type }}
{{- if not (has $t (list "s3" "gcs" "minio" "sharedVolume")) }}
{{- fail "cube: set cubestore.storage.type to s3, gcs, minio or sharedVolume (storage shared by the Cube Store router and workers)" }}
{{- end }}
{{- if and (eq $t "s3") (not .Values.cubestore.storage.s3.bucket) }}{{ fail "cube: set cubestore.storage.s3.bucket" }}{{ end }}
{{- if and (eq $t "gcs") (not .Values.cubestore.storage.gcs.bucket) }}{{ fail "cube: set cubestore.storage.gcs.bucket" }}{{ end }}
{{- if and (eq $t "minio") (or (not .Values.cubestore.storage.minio.endpoint) (not .Values.cubestore.storage.minio.bucket)) }}{{ fail "cube: set cubestore.storage.minio.endpoint and cubestore.storage.minio.bucket" }}{{ end }}
{{- if and (eq $t "minio") (not .Values.cubestore.storage.minio.subPath) }}{{ fail "cube: cubestore.storage.minio.subPath must not be empty (without it, Cube Store cannot list its own uploads on S3-compatible servers)" }}{{ end }}
{{- if and (eq $t "sharedVolume") (not .Values.cubestore.storage.sharedVolume.existingClaim) (not .Values.cubestore.storage.sharedVolume.create) }}{{ fail "cube: set cubestore.storage.sharedVolume.existingClaim or cubestore.storage.sharedVolume.create" }}{{ end }}
{{- if lt (int .Values.cubestore.workers) 1 }}{{ fail "cube: cubestore.workers must be at least 1" }}{{ end }}
{{- else if not .Values.cubestore.external.host }}
{{- fail "cube: with cubestore.enabled=false, set cubestore.external.host to your Cube Store router" }}
{{- end }}
{{- end }}

{{- define "cube.secretData" -}}
{{- if and .Values.apiSecret.value (not .Values.apiSecret.existingSecret) }}
api-secret: {{ .Values.apiSecret.value | b64enc | quote }}
{{- end }}
{{- if and .Values.datasource.password (not .Values.datasource.existingSecret) }}
db-password: {{ .Values.datasource.password | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "cube.createSecret" -}}
{{- if trim (include "cube.secretData" .) }}true{{ end }}
{{- end }}

{{/* Environment shared by the API and the refresh worker. */}}
{{- define "cube.env" -}}
- name: CUBEJS_API_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ default (include "cube.fullname" .) .Values.apiSecret.existingSecret }}
      key: {{ ternary .Values.apiSecret.existingSecretKey "api-secret" (not (empty .Values.apiSecret.existingSecret)) }}
- name: CUBEJS_DB_TYPE
  value: {{ .Values.datasource.type | quote }}
{{- with .Values.datasource.host }}
- name: CUBEJS_DB_HOST
  value: {{ . | quote }}
{{- end }}
{{- with .Values.datasource.port }}
- name: CUBEJS_DB_PORT
  value: {{ . | toString | quote }}
{{- end }}
{{- with .Values.datasource.name }}
- name: CUBEJS_DB_NAME
  value: {{ . | quote }}
{{- end }}
{{- with .Values.datasource.user }}
- name: CUBEJS_DB_USER
  value: {{ . | quote }}
{{- end }}
{{- if or .Values.datasource.password .Values.datasource.existingSecret }}
- name: CUBEJS_DB_PASS
  valueFrom:
    secretKeyRef:
      name: {{ default (include "cube.fullname" .) .Values.datasource.existingSecret }}
      key: {{ ternary .Values.datasource.existingSecretPasswordKey "db-password" (not (empty .Values.datasource.existingSecret)) }}
{{- end }}
- name: CUBEJS_CUBESTORE_HOST
  value: {{ ternary (include "cube.routerName" .) .Values.cubestore.external.host .Values.cubestore.enabled | quote }}
- name: CUBEJS_CUBESTORE_PORT
  value: {{ ternary "3030" (toString .Values.cubestore.external.port) .Values.cubestore.enabled | quote }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Storage env shared by the Cube Store router and workers. */}}
{{- define "cube.cubestoreEnv" -}}
{{- $s := .Values.cubestore.storage }}
- name: CUBESTORE_WORKERS
  value: {{ include "cube.workerList" . | quote }}
- name: CUBESTORE_DATA_DIR
  value: /cube/data
{{- if eq $s.type "s3" }}
- name: CUBESTORE_S3_BUCKET
  value: {{ $s.s3.bucket | quote }}
{{- with $s.s3.region }}
- name: CUBESTORE_S3_REGION
  value: {{ . | quote }}
{{- end }}
{{- with $s.s3.subPath }}
- name: CUBESTORE_S3_SUB_PATH
  value: {{ . | quote }}
{{- end }}
{{- else if eq $s.type "gcs" }}
- name: CUBESTORE_GCS_BUCKET
  value: {{ $s.gcs.bucket | quote }}
{{- with $s.gcs.subPath }}
- name: CUBESTORE_GCS_SUB_PATH
  value: {{ . | quote }}
{{- end }}
{{- else if eq $s.type "minio" }}
- name: CUBESTORE_MINIO_SERVER_ENDPOINT
  value: {{ $s.minio.endpoint | quote }}
- name: CUBESTORE_MINIO_BUCKET
  value: {{ $s.minio.bucket | quote }}
{{- with $s.minio.region }}
- name: CUBESTORE_MINIO_REGION
  value: {{ . | quote }}
{{- end }}
{{- with $s.minio.subPath }}
- name: CUBESTORE_MINIO_SUB_PATH
  value: {{ . | quote }}
{{- end }}
{{- else if eq $s.type "sharedVolume" }}
- name: CUBESTORE_REMOTE_DIR
  value: /cube/remote
{{- end }}
{{- with .Values.cubestore.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Stable worker addresses through the headless Service. */}}
{{- define "cube.workerList" -}}
{{- $list := list }}
{{- range $i := until (int .Values.cubestore.workers) }}
{{- $list = append $list (printf "%s-%d.%s:10001" (include "cube.workerName" $) $i (include "cube.workerHeadless" $)) }}
{{- end }}
{{- join "," $list }}
{{- end }}

{{/* Pod spec of the API and the refresh worker. Call with (list $ "api"|"refresh-worker"). */}}
{{- define "cube.cubePod" -}}
{{- $ := index . 0 }}
{{- $role := index . 1 }}
metadata:
  annotations:
    {{- if include "cube.createSecret" $ }}
    checksum/secret: {{ include "cube.secretData" $ | sha256sum }}
    {{- end }}
    {{- if not $.Values.model.existingConfigMap }}
    checksum/model: {{ toYaml $.Values.model.files | sha256sum }}
    {{- end }}
    {{- with (ternary $.Values.api.podAnnotations $.Values.refreshWorker.podAnnotations (eq $role "api")) }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  labels:
    {{- include "cube.labels" $ | nindent 4 }}
    app.kubernetes.io/component: {{ $role }}
    {{- with $.Values.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  {{- with $.Values.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  serviceAccountName: {{ include "cube.serviceAccountName" $ }}
  automountServiceAccountToken: {{ $.Values.serviceAccount.automount }}
  terminationGracePeriodSeconds: {{ $.Values.terminationGracePeriodSeconds }}
  securityContext:
    {{- toYaml $.Values.podSecurityContext | nindent 4 }}
  initContainers:
    # Kubernetes adds hidden "..data" links to mounted ConfigMap folders, and Cube
    # reads model files through them a second time ("duplicate cube name"). Copy only
    # the real files into the model folder.
    - name: copy-model
      image: {{ include "cube.image" $ }}
      imagePullPolicy: {{ $.Values.image.pullPolicy }}
      command: ["sh", "-c", "cp -L /model-src/* /cube/conf/model/"]
      securityContext:
        {{- toYaml $.Values.securityContext | nindent 8 }}
      volumeMounts:
        - name: model-src
          mountPath: /model-src
          readOnly: true
        - name: model
          mountPath: /cube/conf/model
  containers:
    - name: cube
      image: {{ include "cube.image" $ }}
      imagePullPolicy: {{ $.Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: 4000
          protocol: TCP
      env:
        {{- if eq $role "refresh-worker" }}
        - name: CUBEJS_REFRESH_WORKER
          value: "true"
        {{- end }}
        {{- include "cube.env" $ | nindent 8 }}
      {{- with $.Values.extraEnvFrom }}
      envFrom:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $.Values.api.startupProbe }}
      startupProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $.Values.api.livenessProbe }}
      livenessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if eq $role "api" }}
      {{- with $.Values.api.readinessProbe }}
      readinessProbe:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- end }}
      securityContext:
        {{- toYaml $.Values.securityContext | nindent 8 }}
      {{- with (ternary $.Values.api.resources $.Values.refreshWorker.resources (eq $role "api")) }}
      resources:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      volumeMounts:
        - name: model
          mountPath: /cube/conf/model
          readOnly: true
        {{- with $.Values.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  volumes:
    - name: model-src
      configMap:
        name: {{ include "cube.modelConfigMap" $ }}
    - name: model
      emptyDir: {}
    {{- with $.Values.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $.Values.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $.Values.affinity }}
  affinity:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $.Values.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/* Pod spec parts shared by the Cube Store router and workers. */}}
{{- define "cube.cubestorePodCommon" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "cube.serviceAccountName" . }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount }}
terminationGracePeriodSeconds: {{ .Values.cubestore.terminationGracePeriodSeconds }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
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

{{- define "cube.cubestoreVolumeMounts" -}}
- name: data
  mountPath: /cube/data
{{- if eq .Values.cubestore.storage.type "sharedVolume" }}
- name: remote
  mountPath: /cube/remote
{{- end }}
{{- end }}

{{- define "cube.cubestoreVolumes" -}}
- name: data
  emptyDir: {}
{{- if eq .Values.cubestore.storage.type "sharedVolume" }}
- name: remote
  persistentVolumeClaim:
    claimName: {{ include "cube.sharedClaim" . }}
{{- end }}
{{- end }}
