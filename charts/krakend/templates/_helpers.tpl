{{- define "krakend.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "krakend.fullname" -}}
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

{{- define "krakend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "krakend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "krakend.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "krakend.labels" -}}
helm.sh/chart: {{ include "krakend.chart" . }}
{{ include "krakend.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "krakend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "krakend.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "krakend.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Label that lets a pod through the NetworkPolicy when networkPolicy.from is set. */}}
{{- define "krakend.clientLabel" -}}
{{- printf "%s-client" (include "krakend.fullname" . | trunc 56 | trimSuffix "-") }}
{{- end }}

{{/* True when the chart renders krakend.json from `config` (not flexible config, no existing ConfigMap). */}}
{{- define "krakend.inlineConfig" -}}
{{- if and (not .Values.flexibleConfig.enabled) (not .Values.existingConfigMap) }}true{{ end }}
{{- end }}

{{/* File name of the main configuration inside the pod. */}}
{{- define "krakend.configFile" -}}
{{- if .Values.flexibleConfig.enabled }}krakend.tmpl{{ else }}krakend.json{{ end }}
{{- end }}

{{/* Key of the main configuration in its ConfigMap. */}}
{{- define "krakend.configKey" -}}
{{- if .Values.existingConfigMap }}{{ default (include "krakend.configFile" .) .Values.existingConfigMapKey }}{{ else }}{{ include "krakend.configFile" . }}{{ end }}
{{- end }}

{{- define "krakend.settingsConfigMap" -}}
{{- if .Values.flexibleConfig.existingSettingsConfigMap }}{{ .Values.flexibleConfig.existingSettingsConfigMap }}{{ else if .Values.flexibleConfig.settings }}{{ include "krakend.fullname" . }}-settings{{ end }}
{{- end }}

{{- define "krakend.partialsConfigMap" -}}
{{- if .Values.flexibleConfig.existingPartialsConfigMap }}{{ .Values.flexibleConfig.existingPartialsConfigMap }}{{ else if .Values.flexibleConfig.partials }}{{ include "krakend.fullname" . }}-partials{{ end }}
{{- end }}

{{- define "krakend.templatesConfigMap" -}}
{{- if .Values.flexibleConfig.existingTemplatesConfigMap }}{{ .Values.flexibleConfig.existingTemplatesConfigMap }}{{ else if .Values.flexibleConfig.templates }}{{ include "krakend.fullname" . }}-templates{{ end }}
{{- end }}

{{/*
krakend.json as rendered by the chart: `config`, plus tls.keys with tls.enabled and a
Prometheus exporter with metrics.enabled (unless the config has one).
*/}}
{{- define "krakend.config" -}}
{{- $config := deepCopy .Values.config }}
{{- if .Values.tls.enabled }}
{{- $tls := default (dict) $config.tls }}
{{- $_ := set $tls "keys" (list (dict "public_key" "/etc/krakend/tls/tls.crt" "private_key" "/etc/krakend/tls/tls.key")) }}
{{- $_ := set $config "tls" $tls }}
{{- end }}
{{- if .Values.metrics.enabled }}
{{- $extra := default (dict) $config.extra_config }}
{{- $otel := default (dict) (index $extra "telemetry/opentelemetry") }}
{{- $exporters := default (dict) $otel.exporters }}
{{- if not $exporters.prometheus }}
{{- $_ := set $exporters "prometheus" (list (dict "name" "prometheus" "port" (int .Values.metrics.port) "process_metrics" true "go_metrics" true)) }}
{{- end }}
{{- $_ := set $otel "exporters" $exporters }}
{{- if not $otel.service_name }}
{{- $_ := set $otel "service_name" (include "krakend.fullname" .) }}
{{- end }}
{{- $_ := set $extra "telemetry/opentelemetry" $otel }}
{{- $_ := set $config "extra_config" $extra }}
{{- end }}
{{- toPrettyJson $config }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "krakend.validate" -}}
{{- $fc := .Values.flexibleConfig }}
{{- if and $fc.enabled (not $fc.template) (not .Values.existingConfigMap) }}
{{- fail "krakend: flexibleConfig.enabled needs flexibleConfig.template (the krakend.tmpl template) or existingConfigMap" }}
{{- end }}
{{- if and (not $fc.enabled) (or $fc.template $fc.settings $fc.partials $fc.templates $fc.existingSettingsConfigMap $fc.existingPartialsConfigMap $fc.existingTemplatesConfigMap) }}
{{- fail "krakend: flexibleConfig.template, settings, partials and templates need flexibleConfig.enabled=true" }}
{{- end }}
{{- if and .Values.tls.enabled (not .Values.tls.existingSecret) }}
{{- fail "krakend: tls.enabled needs tls.existingSecret (a kubernetes.io/tls Secret with tls.crt and tls.key)" }}
{{- end }}
{{- if le (int .Values.terminationGracePeriodSeconds) (int .Values.shutdownDelaySeconds) }}
{{- fail "krakend: terminationGracePeriodSeconds must be larger than shutdownDelaySeconds" }}
{{- end }}
{{- if include "krakend.inlineConfig" . }}
{{- $config := .Values.config | default dict }}
{{- if ne (toString $config.version) "4" }}
{{- fail (printf "krakend: config.version must be 4 for KrakenD 3 (got %v). Version 3 is the KrakenD 2.x format; KrakenD 3 refuses it with \"unsupported version: 3 (want: 4)\"" $config.version) }}
{{- end }}
{{- if hasKey $config "port" }}
{{- fail "krakend: set the listening port with the chart value `port`, not config.port (the chart sets KRAKEND_PORT, which overrides config.port)" }}
{{- end }}
{{- $router := dict }}
{{- if $config.extra_config }}{{ $router = default (dict) $config.extra_config.router }}{{ end }}
{{- $probePath := "" }}
{{- if and .Values.readinessProbe .Values.readinessProbe.httpGet }}{{ $probePath = .Values.readinessProbe.httpGet.path }}{{ end }}
{{- if and $router.disable_health $probePath }}
{{- fail "krakend: config.extra_config.router.disable_health turns off the endpoint the probes use; set readinessProbe and livenessProbe to tcpSocket probes (port: http) or keep the health endpoint" }}
{{- end }}
{{- if and $router.health_path $probePath (ne $router.health_path $probePath) }}
{{- fail (printf "krakend: config.extra_config.router.health_path is %q but the probes request %q; set readinessProbe.httpGet.path and livenessProbe.httpGet.path to it" $router.health_path $probePath) }}
{{- end }}
{{- if .Values.metrics.enabled }}
{{- $otel := dict }}
{{- if $config.extra_config }}{{ $otel = default (dict) (index $config.extra_config "telemetry/opentelemetry") }}{{ end }}
{{- if and $otel.exporters $otel.exporters.prometheus }}
{{- $ok := false }}
{{- range $otel.exporters.prometheus }}
{{- if eq (int (default 9090 .port)) (int $.Values.metrics.port) }}{{ $ok = true }}{{ end }}
{{- end }}
{{- if not $ok }}
{{- fail (printf "krakend: none of your Prometheus exporters in config.extra_config.telemetry/opentelemetry listens on metrics.port (%v); set metrics.port to your exporter's port" .Values.metrics.port) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* True when the chart has to create a Secret. */}}
{{- define "krakend.createSecret" -}}
{{- if .Values.secretEnv }}true{{ end }}
{{- end }}

{{/* Checksum of everything the chart renders that KrakenD only reads at startup. */}}
{{- define "krakend.configChecksum" -}}
{{- $parts := list }}
{{- if include "krakend.inlineConfig" . }}{{ $parts = append $parts (include "krakend.config" .) }}{{ end }}
{{- with .Values.flexibleConfig }}
{{- $parts = append $parts (toJson (list .template .settings .partials .templates)) }}
{{- end }}
{{- $parts = append $parts (toJson .Values.secretEnv) }}
{{- join "\n" $parts | sha256sum }}
{{- end }}

{{/* A probe from values, switched to HTTPS with tls.enabled. Argument: list of root context and probe. */}}
{{- define "krakend.probe" -}}
{{- $ := index . 0 }}
{{- $probe := deepCopy (index . 1) }}
{{- if and $.Values.tls.enabled $probe.httpGet }}
{{- $_ := set $probe.httpGet "scheme" "HTTPS" }}
{{- end }}
{{- toYaml $probe }}
{{- end }}

{{/* Environment, volume mounts: shared by KrakenD and the lint init container. */}}
{{- define "krakend.env" -}}
- name: KRAKEND_PORT
  value: {{ .Values.port | quote }}
{{- if not .Values.usageStats }}
- name: USAGE_DISABLE
  value: "1"
{{- end }}
{{- if .Values.flexibleConfig.enabled }}
- name: FC_ENABLE
  value: "1"
{{- if include "krakend.settingsConfigMap" . }}
- name: FC_SETTINGS
  value: /etc/krakend/settings
{{- end }}
{{- if include "krakend.partialsConfigMap" . }}
- name: FC_PARTIALS
  value: /etc/krakend/partials
{{- end }}
{{- if include "krakend.templatesConfigMap" . }}
- name: FC_TEMPLATES
  value: /etc/krakend/templates
{{- end }}
{{- end }}
{{- range $k, $v := .Values.secretEnv }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ include "krakend.fullname" $ }}
      key: {{ $k }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "krakend.envFrom" -}}
{{- if .Values.existingSecret }}
- secretRef:
    name: {{ .Values.existingSecret }}
{{- end }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "krakend.volumeMounts" -}}
- name: config
  mountPath: /etc/krakend/{{ include "krakend.configFile" . }}
  subPath: {{ include "krakend.configKey" . }}
  readOnly: true
{{- if include "krakend.settingsConfigMap" . }}
- name: settings
  mountPath: /etc/krakend/settings
  readOnly: true
{{- end }}
{{- if include "krakend.partialsConfigMap" . }}
- name: partials
  mountPath: /etc/krakend/partials
  readOnly: true
{{- end }}
{{- if include "krakend.templatesConfigMap" . }}
- name: templates
  mountPath: /etc/krakend/templates
  readOnly: true
{{- end }}
{{- if .Values.tls.enabled }}
- name: tls
  mountPath: /etc/krakend/tls
  readOnly: true
{{- end }}
- name: tmp
  mountPath: /tmp
{{- with .Values.extraVolumeMounts }}
{{ toYaml . }}
{{- end }}
{{- end }}
