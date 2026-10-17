{{/*
Deployment for a Saleor process (API, worker or beat); all run the same image.
Arguments (dict): root, component, replicas, command (list, empty = image default),
strategy (optional), grace (termination seconds), port (bool), lifecycle (optional),
probes (dict of probes), resources.
*/}}
{{- define "saleor.deployment" -}}
{{- $ := .root }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "saleor.fullname" $ }}{{ if ne .component "api" }}-{{ .component }}{{ end }}
  labels:
    {{- include "saleor.labels" $ | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  replicas: {{ .replicas }}
  {{- with .strategy }}
  strategy:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "saleor.selectorLabels" $ | nindent 6 }}
      app.kubernetes.io/component: {{ .component }}
  template:
    metadata:
      {{- with (include "saleor.podAnnotations" $ | trim) }}
      annotations:
        {{- . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "saleor.labels" $ | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
        {{- with $.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with $.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "saleor.serviceAccountName" $ }}
      automountServiceAccountToken: {{ $.Values.serviceAccount.automount }}
      terminationGracePeriodSeconds: {{ .grace }}
      securityContext:
        {{- toYaml $.Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .component }}
          image: {{ include "saleor.image" $ }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          {{- with .command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if .port }}
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          {{- end }}
          env:
            {{- include "saleor.env" (list $ (include "saleor.fullname" $)) | trim | nindent 12 }}
          {{- with $.Values.extraEnvFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .lifecycle }}
          lifecycle:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- range $name, $probe := .probes }}
          {{- with $probe }}
          {{ $name }}:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- end }}
          securityContext:
            {{- toYaml $.Values.securityContext | nindent 12 }}
          {{- with .resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            {{- include "saleor.volumeMounts" $ | trim | nindent 12 }}
      volumes:
        {{- include "saleor.volumes" $ | trim | nindent 8 }}
      {{- with (include "saleor.scheduling" $ | trim) }}
      {{- . | nindent 6 }}
      {{- end }}
{{- end }}
