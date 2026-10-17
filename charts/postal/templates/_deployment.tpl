{{/*
Deployment for a Postal process (web server, SMTP server or worker); all run the same image.
Arguments (dict): root, component, replicas, command (list), ports (list of container ports),
grace (termination seconds), lifecycle (optional), probes (dict of rendered probes), resources.

The image's `postal <command>` wrapper is a bash script that runs Ruby as a child process, so
bash would be PID 1 and SIGTERM would never reach Postal (it is killed after the grace period;
a killed worker leaves its message locked for a day). The Deployments pass the commands the
wrapper runs instead; the image's entrypoint execs them, so Ruby is PID 1 and shuts down gracefully.
*/}}
{{- define "postal.deployment" -}}
{{- $ := .root }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "postal.componentName" (list $ .component) }}
  labels:
    {{- include "postal.labels" $ | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      {{- include "postal.selectorLabels" $ | nindent 6 }}
      app.kubernetes.io/component: {{ .component }}
  template:
    metadata:
      {{- with (include "postal.podAnnotations" $ | trim) }}
      annotations:
        {{- . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "postal.labels" $ | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
        {{- with $.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with $.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "postal.serviceAccountName" $ }}
      automountServiceAccountToken: {{ $.Values.serviceAccount.automount }}
      {{- /* Service links inject variables such as RSPAMD_PORT=tcp://..., which Postal would read as its settings. */}}
      enableServiceLinks: false
      terminationGracePeriodSeconds: {{ .grace }}
      securityContext:
        {{- toYaml $.Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .component }}
          image: {{ include "postal.image" $ }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          args: {{ toJson .command }}
          ports:
            {{- toYaml .ports | nindent 12 }}
          env:
            {{- include "postal.env" (list $ (include "postal.fullname" $)) | trim | nindent 12 }}
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
            {{- . | nindent 12 }}
          {{- end }}
          {{- end }}
          securityContext:
            {{- toYaml $.Values.securityContext | nindent 12 }}
          {{- with .resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            {{- include "postal.volumeMounts" $ | trim | nindent 12 }}
      volumes:
        {{- include "postal.volumes" (list $ (include "postal.fullname" $)) | trim | nindent 8 }}
      {{- with (include "postal.scheduling" $ | trim) }}
      {{- . | nindent 6 }}
      {{- end }}
{{- end }}
