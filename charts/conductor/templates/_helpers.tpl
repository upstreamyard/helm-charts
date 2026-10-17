{{- define "conductor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "conductor.fullname" -}}
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

{{- define "conductor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "conductor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "conductor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "conductor.labels" -}}
helm.sh/chart: {{ include "conductor.chart" . }}
{{ include "conductor.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "conductor.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "conductor.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "conductor.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/* Fail early with a clear message on invalid combinations. */}}
{{- define "conductor.validate" -}}
{{- if not .Values.database.url }}
{{- fail "conductor: set database.url, e.g. jdbc:postgresql://postgres:5432/conductor (PostgreSQL is required)" }}
{{- end }}
{{- if not (hasPrefix "jdbc:postgresql://" .Values.database.url) }}
{{- fail "conductor: database.url must be a JDBC URL starting with jdbc:postgresql://" }}
{{- end }}
{{- if not .Values.database.username }}
{{- fail "conductor: set database.username" }}
{{- end }}
{{- if and (not .Values.database.password) (not .Values.database.existingSecret) }}
{{- fail "conductor: set database.password or database.existingSecret" }}
{{- end }}
{{- end }}

{{/* True when the chart has to create a Secret for the database password. */}}
{{- define "conductor.createSecret" -}}
{{- if and .Values.database.password (not .Values.database.existingSecret) }}true{{ end }}
{{- end }}

{{- define "conductor.secretData" -}}
{{- if include "conductor.createSecret" . }}
database-password: {{ .Values.database.password | b64enc | quote }}
{{- end }}
{{- end }}
