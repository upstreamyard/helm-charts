# Aegra Helm chart

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: 0.10.8](https://img.shields.io/badge/AppVersion-0.10.8-informational?style=flat-square)

Helm chart for [Aegra](https://github.com/aegra/aegra), the open-source, self-hosted alternative to LangGraph Platform. It uses the [`upstreamyard/aegra`](https://github.com/upstreamyard/aegra) image.

> Community chart by **upstreamyard**, not an official Aegra chart. Aegra is © its authors, licensed under Apache-2.0.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install aegra upstreamyard/aegra \
  --set database.url='postgresql://user:password@your-postgres:5432/aegra'
```

Or from the OCI registry:

```bash
helm install aegra oci://ghcr.io/upstreamyard/charts/aegra \
  --set database.url='postgresql://user:password@your-postgres:5432/aegra'
```

## Requirements

- **PostgreSQL with the pgvector extension** (required, per [Aegra's docs](https://github.com/aegra/aegra/blob/main/docs/installation.mdx)). The `pgvector/pgvector:pg18` image is Postgres 18 with pgvector included; managed services (RDS, Cloud SQL, Azure) support it too. This chart does not deploy a database.
- **Redis** only when `replicaCount` is greater than 1.

## What the chart does

Follows [Aegra's deployment guide](https://github.com/aegra/aegra/blob/main/docs/guides/deployment.mdx):

- **Migrations:** before every install and upgrade, a Job runs `aegra db upgrade`, and the pods start with `RUN_MIGRATIONS_ON_STARTUP=false`, which the guide recommends for Kubernetes. Set `migrations.enabled=false` to let a single pod migrate on startup instead.
- **Probes:** `/live` for startup and liveness, `/ready` for readiness.
- **Several replicas:** setting `redis.url` (or `redis.existingSecret`) turns on `REDIS_BROKER_ENABLED`. Installing with more than one replica and no Redis fails with an error.
- **Graceful shutdown:** `terminationGracePeriodSeconds: 35`, a few seconds above Aegra's `WORKER_DRAIN_TIMEOUT` (30).
- **Security:** runs as non-root UID 10001, drops all capabilities, and doesn't mount a ServiceAccount token.

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
database:
  existingSecret: aegra-db          # key: database-url
redis:
  existingSecret: aegra-redis       # key: redis-url
extraEnv:
  - name: AUTH_TYPE
    value: custom
extraEnvFrom:
  - secretRef:
      name: llm-api-keys            # e.g. OPENAI_API_KEY
```

Authentication is off by default (`AUTH_TYPE=noop`). See [Aegra's authentication guide](https://github.com/aegra/aegra/blob/main/docs/guides/authentication.mdx) before exposing the service.

## Known issue: first install with several replicas

On the very first install against an empty database, all pods create LangGraph's internal tables at the same moment, and one may fail and get restarted by the startup probe (about 1–2 minutes). It recovers on its own, and later upgrades are not affected. To avoid it, do the first install with `replicaCount: 1` and scale up afterwards.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the connection string (recommended for production). |
| database.existingSecretKey | string | `"database-url"` | Key in `existingSecret` that holds the connection string. |
| database.url | string | `""` | Connection string `postgresql://user:password@host:5432/db`. URL-encode special characters in the password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| extraEnv | list | `[]` | Extra environment variables for Aegra, e.g. `AUTH_TYPE`, `ENV_MODE`, OTEL settings. See https://github.com/aegra/aegra/blob/main/.env.example |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps, e.g. a Secret with `OPENAI_API_KEY`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"upstreamyard/aegra"` | Image repository. Use your own image built `FROM upstreamyard/aegra` to serve your own graphs. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"aegra.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"httpGet":{"path":"/live","port":"http"},"periodSeconds":10}` | Liveness probe on `/live`, as in Aegra's docs. |
| migrations.activeDeadlineSeconds | int | `600` | Maximum runtime of the migration Job in seconds. |
| migrations.backoffLimit | int | `3` | Retries of the migration Job before the install/upgrade fails. |
| migrations.enabled | bool | `true` | Run `aegra db upgrade` in a Job before every install and upgrade (Helm hook), and disable migrations on pod startup. This is the approach Aegra's docs recommend for Kubernetes. If false, each pod migrates on startup, which is fine for a single replica. |
| migrations.resources | object | `{}` | Resources for the migration Job. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as non-root UID 10001. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/ready","port":"http"},"periodSeconds":5}` | Readiness probe on `/ready` (503 until the database and LangGraph backends respond), as in Aegra's docs. |
| redis.existingSecret | string | `""` | Name of an existing Secret that holds the Redis URL. |
| redis.existingSecretKey | string | `"redis-url"` | Key in `existingSecret` that holds the Redis URL. |
| redis.url | string | `""` | Redis URL, e.g. `redis://redis:6379/0`. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| replicaCount | int | `1` | Number of Aegra pods. More than 1 requires `redis` (Aegra needs Redis to share streaming and the job queue). |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"250m","memory":"512Mi"}}` | Resources for the Aegra container. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Container security context. |
| service.port | int | `2026` | Service port. Aegra listens on 2026 inside the container. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Aegra does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":30,"httpGet":{"path":"/live","port":"http"},"periodSeconds":2}` | Startup probe. `/live` checks only that the process is up. |
| terminationGracePeriodSeconds | int | `35` | Seconds Kubernetes waits after SIGTERM. Aegra's docs: a few seconds above `WORKER_DRAIN_TIMEOUT` (default 30) so running agent runs can finish. |
| tolerations | list | `[]` | Tolerations. |
