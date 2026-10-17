{{- define "nemo-guardrails.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nemo-guardrails.fullname" -}}
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

{{- define "nemo-guardrails.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nemo-guardrails.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nemo-guardrails.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nemo-guardrails.labels" -}}
helm.sh/chart: {{ include "nemo-guardrails.chart" . }}
{{ include "nemo-guardrails.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "nemo-guardrails.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nemo-guardrails.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "nemo-guardrails.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/*
Name of the ConfigMap the chart creates for a configuration from `configs`. It ends in a
hash of the files: Kubernetes updates mounted ConfigMaps inside running pods, and the
server loads configurations lazily, so changing a ConfigMap in place would hand new (maybe
broken) files to the old pods during a rollout. A new name per change avoids that.
*/}}
{{- define "nemo-guardrails.configMapName" -}}
{{- $ := index . 0 }}
{{- $id := index . 1 }}
{{- $hash := toJson (index $.Values.configs $id) | sha256sum | trunc 8 }}
{{- $base := printf "%s-%s" (include "nemo-guardrails.fullname" $) ($id | replace "_" "-" | lower) | trunc 54 | trimSuffix "-" }}
{{- printf "%s-%s" $base $hash }}
{{- end }}

{{/* Config ids from `configs` and `existingConfigMaps`, as a JSON list. */}}
{{- define "nemo-guardrails.configIds" -}}
{{- $ids := keys .Values.configs | sortAlpha }}
{{- range .Values.existingConfigMaps }}
{{- $ids = append $ids .id }}
{{- end }}
{{- toJson $ids }}
{{- end }}

{{- define "nemo-guardrails.hasConfigs" -}}
{{- if or .Values.configs .Values.existingConfigMaps }}true{{ end }}
{{- end }}

{{- define "nemo-guardrails.defaultConfigId" -}}
{{- $ids := include "nemo-guardrails.configIds" . | fromJsonArray }}
{{- if .Values.defaultConfigId }}
{{- .Values.defaultConfigId }}
{{- else if eq (len $ids) 1 }}
{{- first $ids }}
{{- else }}
{{- "config" }}
{{- end }}
{{- end }}

{{- define "nemo-guardrails.createSecret" -}}
{{- if and (not .Values.llm.existingSecret) (or .Values.llm.openaiApiKey .Values.llm.nvidiaApiKey) }}true{{ end }}
{{- end }}

{{- define "nemo-guardrails.secretData" -}}
{{- with .Values.llm.openaiApiKey }}
OPENAI_API_KEY: {{ . | b64enc | quote }}
{{- end }}
{{- with .Values.llm.nvidiaApiKey }}
NVIDIA_API_KEY: {{ . | b64enc | quote }}
{{- end }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "nemo-guardrails.validate" -}}
{{- $ids := include "nemo-guardrails.configIds" . | fromJsonArray }}
{{- range $ids }}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9_-]*$" .) }}
{{- fail (printf "nemo-guardrails: config id %q may only contain letters, digits, '-' and '_'" .) }}
{{- end }}
{{- end }}
{{- if ne (len $ids) (len (uniq $ids)) }}
{{- fail "nemo-guardrails: a config id is used twice in configs and existingConfigMaps" }}
{{- end }}
{{- range $id, $files := .Values.configs }}
{{- if not (or (hasKey $files "config.yml") (hasKey $files "config.yaml")) }}
{{- fail (printf "nemo-guardrails: configs.%s needs a config.yml" $id) }}
{{- end }}
{{- end }}
{{- if and (gt (len $ids) 1) (not .Values.defaultConfigId) }}
{{- fail (printf "nemo-guardrails: several configurations (%s): set defaultConfigId to the one for requests without guardrails.config_id" (join ", " $ids)) }}
{{- end }}
{{- if and .Values.defaultConfigId $ids (not (has .Values.defaultConfigId $ids)) }}
{{- fail (printf "nemo-guardrails: defaultConfigId %q is not one of the configurations (%s)" .Values.defaultConfigId (join ", " $ids)) }}
{{- end }}
{{- end }}

{{/* Volume mounts shared by the server and the config check. */}}
{{- define "nemo-guardrails.volumeMounts" -}}
- name: tmp
  mountPath: /tmp
{{- if include "nemo-guardrails.hasConfigs" . }}
{{- /* Hides the image's default configuration, so /config holds only the sub-folders. */}}
- name: config-root
  mountPath: /config
{{- end }}
{{- range $id, $_ := .Values.configs }}
- name: config-{{ $id | replace "_" "-" | lower }}
  mountPath: /config/{{ $id }}
  readOnly: true
{{- end }}
{{- range .Values.existingConfigMaps }}
- name: config-{{ .id | replace "_" "-" | lower }}
  mountPath: /config/{{ .id }}
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* Environment shared by the server and the config check. */}}
{{- define "nemo-guardrails.envFrom" -}}
{{- if include "nemo-guardrails.createSecret" . }}
- secretRef:
    name: {{ include "nemo-guardrails.fullname" . }}
{{- end }}
{{- with .Values.llm.existingSecret }}
- secretRef:
    name: {{ . }}
{{- end }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}
