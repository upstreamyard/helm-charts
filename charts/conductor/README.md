# Conductor Helm chart

![Version: 0.1.3](https://img.shields.io/badge/Version-0.1.3-informational?style=flat-square) ![AppVersion: 3.33.0](https://img.shields.io/badge/AppVersion-3.33.0-informational?style=flat-square)

> **Support:** For help with setup, production issues or custom changes, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for [Conductor OSS](https://github.com/conductor-oss/conductor), the open-source workflow orchestration engine originally built at Netflix. It uses the [`upstreamyard/conductor`](https://github.com/upstreamyard/conductor) image, which contains the server and the UI.

> Community chart by **upstreamyard**, not an official Conductor chart. Conductor is © its authors, licensed under Apache-2.0.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install conductor upstreamyard/conductor \
  --set database.url='jdbc:postgresql://your-postgres:5432/conductor' \
  --set database.username=conductor \
  --set database.password='...'
```

Or from the OCI registry:

```bash
helm install conductor oci://ghcr.io/upstreamyard/charts/conductor \
  --set database.url='jdbc:postgresql://your-postgres:5432/conductor' \
  --set database.username=conductor \
  --set database.password='...'
```

Then open the UI:

```bash
kubectl port-forward svc/conductor 5000:5000   # http://localhost:5000
```

Your workers connect to `http://conductor.<namespace>.svc:8080/api`.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install conductor upstreamyard/conductor --verify --keyring upstreamyard.gpg --set database.url='...'
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **PostgreSQL** (required). Tested with PostgreSQL 16. Managed services (RDS, Cloud SQL, Azure) work too. Conductor creates its tables on startup, so the user needs permission to create tables in the database. This chart does not deploy a database.
- Nothing else: queues, the search index, workflow payloads and locks are all stored in PostgreSQL.

## What the chart does

- **One database for everything:** sets Conductor to use PostgreSQL for persistence, queues, indexing, payloads and the workflow lock.
- **Several replicas:** the workflow lock lives in PostgreSQL (`conductor.workflow-execution-lock.type=postgres`), so all pods coordinate through the database and you can change `replicaCount` at any time. Conductor's own default lock only works within one process.
- **Migrations:** Conductor migrates the database itself on startup (Flyway, with a database lock), so there's no migration Job.
- **Probes:** `/health` for startup and liveness (process only, so a database outage doesn't restart pods), `/actuator/health` for readiness (includes the database).
- **UI and API in one pod:** the Service exposes the API on `8080` and the UI on `5000`. The UI proxies `/api` to the server in the same pod, so the Ingress points at the UI port and serves both.
- **Graceful shutdown:** Conductor stops within 30 seconds after SIGTERM; `terminationGracePeriodSeconds` is 35.
- **Security:** runs as non-root UID 10001, drops all capabilities, and doesn't mount a ServiceAccount token.

**Authentication:** Conductor OSS has none. Anyone who can reach the Service or the Ingress can create, run and delete workflows. Keep the Service internal, or put an authenticating proxy or Ingress controller (e.g. OAuth2 Proxy) in front.

## Configuration

Any Conductor or Spring Boot property can be set through `extraEnv`: upper-case, with `.` and `-` replaced by `_`:

```yaml
extraEnv:
  - name: CONDUCTOR_APP_WORKFLOWOFFSETTIMEOUT   # conductor.app.workflowOffsetTimeout
    value: 30s
  - name: OPENAI_API_KEY                        # for Conductor's LLM tasks
    valueFrom:
      secretKeyRef:
        name: llm-keys
        key: openai
```

All properties and their defaults are in the Conductor project's [`application.properties`](https://github.com/conductor-oss/conductor/blob/main/server/src/main/resources/application.properties).

To use a properties file instead, mount it into `/app/config` and select it with `CONFIG_PROP`. Values from the file override environment variables, including the ones this chart sets, and a missing file stops the container with an error.

```yaml
extraVolumes:
  - name: config
    configMap:
      name: conductor-config            # key: custom.properties
extraVolumeMounts:
  - name: config
    mountPath: /app/config/custom.properties
    subPath: custom.properties
extraEnv:
  - name: CONFIG_PROP
    value: custom.properties
```

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
database:
  url: jdbc:postgresql://conductor-db.example.internal:5432/conductor?sslmode=require
  username: conductor
  existingSecret: conductor-db        # key: password
resources:
  requests:
    cpu: "1"
    memory: 2Gi
  limits:
    memory: 4Gi
ingress:
  enabled: true
  className: nginx                     # plus your controller's authentication annotations
  hosts:
    - host: conductor.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: conductor-tls
      hosts: [conductor.example.com]
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the password (recommended for production). |
| database.existingSecretPasswordKey | string | `"password"` | Key in `existingSecret` that holds the password. |
| database.password | string | `""` | Database password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| database.url | string | `""` | JDBC URL, e.g. `jdbc:postgresql://postgres:5432/conductor`. Append `?sslmode=require` for TLS. |
| database.username | string | `""` | Database user. |
| extraEnv | list | `[]` | Extra environment variables. Any Conductor or Spring Boot property can be set this way: upper-case, `.` and `-` become `_` (`conductor.app.workflowOffsetTimeout` → `CONDUCTOR_APP_WORKFLOWOFFSETTIMEOUT`). See https://github.com/conductor-oss/conductor/blob/main/server/src/main/resources/application.properties |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Conductor container. Properties files go into `/app/config`; select one with `CONFIG_PROP` in `extraEnv`. |
| extraVolumes | list | `[]` | Extra volumes for the pod, e.g. a ConfigMap with a properties file. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"upstreamyard/conductor"` | Image repository. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. It routes to the UI port, which also serves `/api`, `/swagger-ui` and `/actuator` through the UI's proxy. Conductor has no authentication, so put an authenticating proxy or ingress in front. |
| ingress.hosts | list | `[{"host":"conductor.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| javaOpts | string | `"-XX:MaxRAMPercentage=75.0"` | JVM options (`JAVA_OPTS`). The heap follows the container memory limit. |
| livenessProbe | object | `{"httpGet":{"path":"/health","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on `/health` (process only), so a database outage does not restart healthy pods. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as non-root UID 10001. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/actuator/health","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Readiness probe on `/actuator/health`, which checks the database. Pods leave the Service while PostgreSQL is unreachable. |
| replicaCount | int | `1` | Number of Conductor pods. All pods share the PostgreSQL database; the chart always uses Conductor's PostgreSQL workflow lock, so you can scale up or down at any time. |
| resources | object | `{"limits":{"memory":"2Gi"},"requests":{"cpu":"250m","memory":"1Gi"}}` | Resources for the Conductor container. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Container security context. |
| service.port | int | `8080` | Port of the REST API (`/api`), Swagger UI and metrics. Workers connect to `http://<service>:<port>/api`. |
| service.type | string | `"ClusterIP"` | Service type. |
| service.uiPort | int | `5000` | Port of the UI. The UI also proxies `/api` to the server in the same pod. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Conductor does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/health","port":"http"},"periodSeconds":2}` | Startup probe. `/health` checks only that the server process is up. Allows up to 2 minutes for the first start, which creates the database tables. |
| terminationGracePeriodSeconds | int | `35` | Seconds Kubernetes waits after SIGTERM. Conductor (Spring Boot) shuts down gracefully within 30 seconds. |
| tolerations | list | `[]` | Tolerations. |
