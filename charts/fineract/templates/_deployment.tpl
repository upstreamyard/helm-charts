{{/*
A Fineract Deployment: (list $ component role replicas resources strategy shareDocuments).
component: write, read or batch (resource names and labels); role: see fineract.env.
*/}}
{{- define "fineract.deployment" -}}
{{- $ := index . 0 }}
{{- $component := index . 1 }}
{{- $role := index . 2 }}
{{- $replicas := index . 3 }}
{{- $resources := index . 4 }}
{{- $strategy := index . 5 }}
{{- $documents := index . 6 }}
{{- $name := ternary (include "fineract.fullname" $) (include "fineract.componentName" (list $ $component)) (eq $component "write") }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    {{- include "fineract.labels" $ | nindent 4 }}
    app.kubernetes.io/component: {{ $component }}
spec:
  replicas: {{ $replicas }}
  strategy:
    type: {{ $strategy }}
  selector:
    matchLabels:
      {{- include "fineract.selectorLabels" $ | nindent 6 }}
      app.kubernetes.io/component: {{ $component }}
  template:
    metadata:
      labels:
        {{- include "fineract.selectorLabels" $ | nindent 8 }}
        app.kubernetes.io/component: {{ $component }}
        {{- with $.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      annotations:
        checksum/config: {{ toJson (list $.Values.database $.Values.tenant $.Values.admin $.Values.tls.mode) | sha256sum }}
        {{- with $.Values.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with $.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "fineract.serviceAccountName" $ }}
      automountServiceAccountToken: false
      {{- /* Service links would inject variables such as FINERACT_SERVER_PORT for a Service
      named "fineract-server", which Fineract reads as its own settings. */}}
      enableServiceLinks: false
      terminationGracePeriodSeconds: {{ $.Values.terminationGracePeriodSeconds }}
      securityContext:
        {{- toYaml $.Values.podSecurityContext | nindent 8 }}
      containers:
        - name: fineract
          image: {{ include "fineract.image" $ }}
          imagePullPolicy: {{ $.Values.image.pullPolicy }}
          ports:
            - name: {{ include "fineract.portName" $ }}
              containerPort: {{ include "fineract.port" $ }}
          env:
            {{- include "fineract.env" (list $ (include "fineract.fullname" $) $role) | nindent 12 }}
          {{- with $.Values.extraEnvFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          startupProbe:
            httpGet:
              path: /fineract-provider/actuator/health/liveness
              port: {{ include "fineract.portName" $ }}
              scheme: {{ include "fineract.scheme" $ }}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: {{ $.Values.probes.startupFailureThreshold }}
          livenessProbe:
            httpGet:
              path: /fineract-provider/actuator/health/liveness
              port: {{ include "fineract.portName" $ }}
              scheme: {{ include "fineract.scheme" $ }}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: {{ $.Values.probes.livenessFailureThreshold }}
          readinessProbe:
            httpGet:
              path: /fineract-provider/actuator/health/readiness
              port: {{ include "fineract.portName" $ }}
              scheme: {{ include "fineract.scheme" $ }}
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: {{ $.Values.probes.readinessFailureThreshold }}
          securityContext:
            {{- toYaml $.Values.securityContext | nindent 12 }}
          resources:
            {{- toYaml $resources | nindent 12 }}
          volumeMounts:
            - name: tmp
              mountPath: /tmp
            - name: documents
              mountPath: /var/lib/fineract
            {{- if eq $.Values.tls.mode "secret" }}
            - name: tls
              mountPath: /etc/fineract/tls
              readOnly: true
            {{- end }}
            {{- with $.Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: tmp
          emptyDir: {}
        - name: documents
          {{- if $documents }}
          persistentVolumeClaim:
            claimName: {{ include "fineract.claimName" $ }}
          {{- else }}
          emptyDir: {}
          {{- end }}
        {{- if eq $.Values.tls.mode "secret" }}
        - name: tls
          secret:
            secretName: {{ include "fineract.tlsSecretName" $ }}
        {{- end }}
        {{- with $.Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      affinity:
        {{- if $.Values.affinity }}
        {{- toYaml $.Values.affinity | nindent 8 }}
        {{- else }}
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    {{- include "fineract.selectorLabels" $ | nindent 20 }}
                    app.kubernetes.io/component: {{ $component }}
        {{- end }}
{{- end }}
