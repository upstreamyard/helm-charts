{{- define "plano.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "plano.fullname" -}}
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

{{- define "plano.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "plano.selectorLabels" -}}
app.kubernetes.io/name: {{ include "plano.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "plano.labels" -}}
helm.sh/chart: {{ include "plano.chart" . }}
{{ include "plano.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "plano.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "plano.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "plano.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{- define "plano.postgresEnabled" -}}
{{- if or .Values.stateStorage.postgres.url .Values.stateStorage.postgres.existingSecret }}true{{ end }}
{{- end }}

{{- define "plano.redisEnabled" -}}
{{- if or .Values.sessionCache.redis.url .Values.sessionCache.redis.existingSecret }}true{{ end }}
{{- end }}

{{/*
plano_config.yaml as rendered by the chart: `config` plus state_storage and
routing.session_cache pointing at environment variables set from Secrets.
*/}}
{{- define "plano.config" -}}
{{- $config := deepCopy .Values.config }}
{{- if include "plano.postgresEnabled" . }}
{{- $_ := set $config "state_storage" (dict "type" "postgres" "connection_string" "$PLANO_STATE_POSTGRES_URL") }}
{{- end }}
{{- if include "plano.redisEnabled" . }}
{{- $routing := default (dict) $config.routing }}
{{- $_ := set $routing "session_cache" (dict "type" "redis" "url" "$PLANO_SESSION_CACHE_REDIS_URL") }}
{{- $_ := set $config "routing" $routing }}
{{- end }}
{{- toYaml $config }}
{{- end }}

{{/* Lowercase DNS label for a port name, at most 15 characters. */}}
{{- define "plano.portName" -}}
{{- regexReplaceAll "[^a-z0-9-]" (lower .) "-" | trunc 15 | trimSuffix "-" | trimPrefix "-" }}
{{- end }}

{{/*
Ports as a JSON list of {name, port}: `ports`, or one per listener in `config`.
The model listener's port is called "llm" (the probes use it). Plano always runs
its LLM gateway on 12000 unless a model listener sets another port.
*/}}
{{- define "plano.ports" -}}
{{- $ports := list }}
{{- if .Values.ports }}
{{- $ports = .Values.ports }}
{{- else }}
{{- $llm := 12000 }}
{{- $others := list }}
{{- range $i, $l := (.Values.config.listeners | default list) }}
{{- if eq (toString $l.type) "model" }}
{{- $llm = int (default 12000 $l.port) }}
{{- else }}
{{- $default := ternary 10000 0 (eq (toString $l.type) "prompt") }}
{{- $port := int (default $default $l.port) }}
{{- if not $port }}
{{- fail (printf "plano: listener %q has no port; set config.listeners[%d].port" (toString $l.name) $i) }}
{{- end }}
{{- $others = append $others (dict "name" (include "plano.portName" (default (printf "%s-%d" $l.type $port) $l.name)) "port" $port) }}
{{- end }}
{{- end }}
{{- $ports = prepend $others (dict "name" "llm" "port" $llm) }}
{{- end }}
{{- toJson $ports }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "plano.validate" -}}
{{- $config := .Values.config | default dict }}
{{- if and .Values.existingConfigMap (not .Values.ports) }}
{{- fail "plano: existingConfigMap needs ports (a list of name/port; name the model listener's port \"llm\")" }}
{{- end }}
{{- if and .Values.existingConfigMap (or (include "plano.postgresEnabled" .) (include "plano.redisEnabled" .)) }}
{{- fail "plano: stateStorage and sessionCache can't be added to existingConfigMap; configure state_storage and routing.session_cache in your file" }}
{{- end }}
{{- if and (not .Values.existingConfigMap) (include "plano.postgresEnabled" .) $config.state_storage }}
{{- fail "plano: set either stateStorage.postgres or config.state_storage, not both" }}
{{- end }}
{{- if and (not .Values.existingConfigMap) (include "plano.redisEnabled" .) $config.routing }}
{{- if $config.routing.session_cache }}
{{- fail "plano: set either sessionCache.redis or config.routing.session_cache, not both" }}
{{- end }}
{{- end }}
{{- if regexMatch "sslmode=(require|verify-ca|verify-full)" .Values.stateStorage.postgres.url }}
{{- fail "plano: Plano connects to PostgreSQL without TLS and fails with sslmode=require/verify-* (\"error performing TLS handshake\"); use a server that accepts connections without TLS" }}
{{- end }}
{{- $multi := or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled }}
{{- if and $multi (not .Values.existingConfigMap) $config.state_storage }}
{{- if eq (toString $config.state_storage.type) "memory" }}
{{- fail "plano: state_storage type memory keeps conversations in one pod; with more than 1 replica use stateStorage.postgres" }}
{{- end }}
{{- end }}
{{- if le (int .Values.terminationGracePeriodSeconds) (int .Values.shutdownDelaySeconds) }}
{{- fail "plano: terminationGracePeriodSeconds must be larger than shutdownDelaySeconds" }}
{{- end }}
{{- $names := dict }}
{{- range (include "plano.ports" . | fromJsonArray) }}
{{- if hasKey $names .name }}
{{- fail (printf "plano: two ports are named %q; rename the listener or set ports" .name) }}
{{- end }}
{{- $_ := set $names .name true }}
{{- end }}
{{- if not (hasKey $names "llm") }}
{{- fail "plano: ports needs an entry named \"llm\" (the model listener's port, used by the probes)" }}
{{- end }}
{{- end }}

{{/* True when the chart has to create a Secret. */}}
{{- define "plano.createSecret" -}}
{{- if or .Values.secretEnv (and .Values.stateStorage.postgres.url (not .Values.stateStorage.postgres.existingSecret)) (and .Values.sessionCache.redis.url (not .Values.sessionCache.redis.existingSecret)) }}true{{ end }}
{{- end }}

{{- define "plano.secretData" -}}
{{- range $k, $v := .Values.secretEnv }}
{{ $k }}: {{ toString $v | b64enc | quote }}
{{- end }}
{{- if and .Values.stateStorage.postgres.url (not .Values.stateStorage.postgres.existingSecret) }}
postgres-url: {{ .Values.stateStorage.postgres.url | b64enc | quote }}
{{- end }}
{{- if and .Values.sessionCache.redis.url (not .Values.sessionCache.redis.existingSecret) }}
redis-url: {{ .Values.sessionCache.redis.url | b64enc | quote }}
{{- end }}
{{- end }}

{{/* secretKeyRef for the PostgreSQL URL. Argument: list of root context and chart Secret name. */}}
{{- define "plano.postgresSecretRef" -}}
{{- $ := index . 0 }}
secretKeyRef:
  {{- if $.Values.stateStorage.postgres.existingSecret }}
  name: {{ $.Values.stateStorage.postgres.existingSecret }}
  key: {{ $.Values.stateStorage.postgres.existingSecretKey }}
  {{- else }}
  name: {{ index . 1 }}
  key: postgres-url
  {{- end }}
{{- end }}

{{/* Label that lets a pod through the NetworkPolicy when networkPolicy.from is set. */}}
{{- define "plano.clientLabel" -}}
{{- printf "%s-client" (include "plano.fullname" . | trunc 56 | trimSuffix "-") }}
{{- end }}

{{/* Port number of the "llm" port (the model listener). */}}
{{- define "plano.llmPort" -}}
{{- range (include "plano.ports" . | fromJsonArray) }}
{{- if eq .name "llm" }}{{ int .port }}{{ end }}
{{- end }}
{{- end }}
