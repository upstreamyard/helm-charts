# SuperTokens Helm chart

![Version: 0.1.1](https://img.shields.io/badge/Version-0.1.1-informational?style=flat-square) ![AppVersion: 12.4.1](https://img.shields.io/badge/AppVersion-12.4.1-informational?style=flat-square)

Helm chart for the [SuperTokens](https://github.com/supertokens/supertokens-core) core, the open-source authentication server behind SuperTokens' backend SDKs: sessions, email/password, passwordless, social and enterprise login, MFA, roles and multi-tenancy. It uses SuperTokens' official image [`supertokens/supertokens-postgresql`](https://hub.docker.com/r/supertokens/supertokens-postgresql).

> Community chart by **upstreamyard**, not an official SuperTokens chart. SuperTokens is © SuperTokens Inc., licensed under Apache-2.0; its paid features (account linking, multi-tenancy, MFA, dashboard logins, OAuth provider, SAML, security features) need a SuperTokens licence key and fall under the licence in its `ee/` folder.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install supertokens upstreamyard/supertokens \
  --set supertokens.apiKeys=$(openssl rand -hex 32) \
  --set database.uri='postgresql://user:password@your-postgres:5432/supertokens'
```

Or from the OCI registry:

```bash
helm install supertokens oci://ghcr.io/upstreamyard/charts/supertokens --set supertokens.apiKeys=... --set database.uri=...
```

Then point your backend SDK at the core, with the same API key:

```js
supertokens.init({
  supertokens: {
    connectionURI: "http://supertokens.<namespace>.svc.cluster.local:3567",
    apiKey: "<your API key>",
  },
  // ...
});
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install supertokens upstreamyard/supertokens --verify --keyring upstreamyard.gpg --set ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **PostgreSQL** (required). SuperTokens' notes for 12.2 assume PostgreSQL 14 or newer; this chart is tested with PostgreSQL 18. This chart does not deploy a database.
- Your backend, running one of SuperTokens' backend SDKs, must reach the Service. Browsers and apps talk to your backend, not to the core.

## What the chart does

- **Configuration:** the core reads every option of its `config.yaml` from an environment variable with the upper-case name (`ACCESS_TOKEN_VALIDITY`, `PASSWORD_HASHING_ALG`, …). The chart sets the API keys, the database URI, the table schema, log level, telemetry and the schema check; add others with `extraEnv`. Logs go to stdout (`kubectl logs`), not to files in the container. At SuperTokens' default level `INFO` every request is logged, including the probes' (two lines every 5 seconds per pod); `supertokens.logLevel: WARN` keeps only warnings and errors.
- **API key required:** the chart refuses to install without `supertokens.apiKeys` or `supertokens.existingSecret`. Without a key, anyone who can reach the core can create, read and delete users. Changing `supertokens.apiKeys` restarts the pods. To rotate a key without failed requests, add the new key next to the old one (`old,new`), switch your backend to the new key, then remove the old one: during a rollout, old and new pods briefly serve side by side.
- **No migration Job:** on a fresh database the core creates its tables itself. Upgrades can need manual SQL, see [Upgrading](#upgrading).
- **Probes:** `/hello` for startup and readiness. It returns 200 only while the core can query the database, so during a database outage pods leave the Service instead of serving errors. Liveness is a TCP check, because restarting the core doesn't fix a database outage.
- **Several replicas:** the core keeps no local state, so `replicaCount` can be raised. In our tests, two pods starting at once on an empty database created the schema without errors, and a rolling update under constant requests had no failed request.
- **Shutdown:** the image's start script runs as PID 1 and ignores `SIGTERM`, which would leave every pod hanging until it's killed. The chart's `preStop` hook waits `shutdownDelaySeconds` (5) while the pod leaves the Service, then sends `SIGTERM` to the core, which shuts down cleanly.
- **Security:** runs as the image's `supertokens` user (UID 1000) with a read-only root filesystem (the core's temp files go to an emptyDir), drops all capabilities, and doesn't mount a ServiceAccount token.
- **`helm test`** checks `/hello`, that a call without the API key is refused (401) and that a call with it reads the database.

## Upgrading

SuperTokens creates missing tables at startup but never adds columns to existing ones. Some versions therefore need SQL run by hand **before** the upgrade, listed under "Migration" in [SuperTokens' CHANGELOG](https://github.com/supertokens/supertokens-core/blob/master/CHANGELOG.md) (e.g. 12.1.0 added two columns to `session_info`). Since 12.2.0 the core checks the schema at startup and, with `supertokens.schemaCheckStrictMode: true` (the default), refuses to start until the SQL has been run.

Before `helm upgrade` to a new SuperTokens version:

1. Read the "Migration" sections of every version between yours and the new one.
2. Run the SQL against your database (use `CREATE INDEX CONCURRENTLY` on large tables, as the notes say).
3. Upgrade the chart.

If you miss a step, nothing breaks for your users. We tested 12.0.10 → 12.2.0 without the SQL: the new pod exits with `Database schema is out of date` and prints the exact `ALTER TABLE` statements in its log (`kubectl logs`), while the old pods keep serving and `helm upgrade` times out. After running those statements, the new pod started on its next restart and the rollout finished; existing users could sign in. Run `helm upgrade` once more to mark the release as deployed.

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
supertokens:
  existingSecret: supertokens          # key: api-keys
  telemetry: false
database:
  existingSecret: supertokens-db       # key: uri
resources:
  requests: { cpu: 500m, memory: 512Mi }
  limits: { memory: 1Gi }
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels: { app.kubernetes.io/name: supertokens }
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the connection URI (recommended for production). |
| database.existingSecretKey | string | `"uri"` | Key in `existingSecret` that holds the connection URI. |
| database.schema | string | `""` | PostgreSQL schema for SuperTokens' tables (`POSTGRESQL_TABLE_SCHEMA`). Empty uses `public`. |
| database.uri | string | `""` | Connection URI, e.g. `postgresql://user:password@postgres:5432/supertokens` (`POSTGRESQL_CONNECTION_URI`). Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| extraEnv | list | `[]` | Extra environment variables. Every option in SuperTokens' config.yaml can be set by its upper-case name, e.g. `ACCESS_TOKEN_VALIDITY`, `PASSWORD_HASHING_ALG`, `POSTGRESQL_CONNECTION_POOL_SIZE`. See https://github.com/supertokens/supertokens-core/blob/master/config.yaml and https://github.com/supertokens/supertokens-postgresql-plugin/blob/master/config.yaml |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the SuperTokens container. |
| extraVolumes | list | `[]` | Extra volumes for the pods. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"supertokens/supertokens-postgresql"` | Image repository. SuperTokens' official image for PostgreSQL. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. Usually not needed: only your backend talks to the core, never browsers or apps. If you enable it, keep `supertokens.apiKeys` set. |
| ingress.hosts | list | `[{"host":"supertokens.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"tcpSocket":{"port":"http"},"timeoutSeconds":5}` | Liveness probe. A TCP check on purpose: `/hello` fails while the database is down, and restarting the core doesn't help then. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as the `supertokens` user, UID 1000. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/hello","port":"http"},"periodSeconds":5,"timeoutSeconds":3}` | Readiness probe on `/hello`. Pods leave the Service while they can't reach the database. |
| replicaCount | int | `1` | Number of SuperTokens core pods. The core keeps no local state, so it scales horizontally. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"384Mi"}}` | Resources for the SuperTokens container. The core (Java) used about 200 MiB idle in our tests. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The core's temp files go to emptyDirs, so the root filesystem is read-only. |
| service.port | int | `3567` | Service port. SuperTokens' SDKs default to port 3567 in `connectionURI`. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. SuperTokens does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| shutdownDelaySeconds | int | `5` | Seconds the pod waits after it's removed from the Service before the core is told to stop. The image's start script ignores `SIGTERM`, so the chart stops the core itself in a `preStop` hook. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/hello","port":"http"},"periodSeconds":2,"timeoutSeconds":5}` | Startup probe on `/hello`, which answers only once the core is up and can query the database. |
| supertokens.apiKeys | string | `""` | API key(s) your backend SDK sends in the `api-key` header (`API_KEYS`). Comma-separated, each at least 20 characters of `A-Z a-z 0-9 = -`, e.g. from `openssl rand -hex 32`. Stored in a Secret created by this chart. Required unless `existingSecret` is set: without a key, anyone who can reach the Service can manage your users. |
| supertokens.existingSecret | string | `""` | Name of an existing Secret that holds the API key(s). |
| supertokens.existingSecretKey | string | `"api-keys"` | Key in `existingSecret` that holds the API key(s). |
| supertokens.logLevel | string | `""` | Log level (`LOG_LEVEL`): `DEBUG`, `INFO`, `WARN`, `ERROR` or `NONE`. Empty keeps SuperTokens' default (`INFO`). |
| supertokens.schemaCheckStrictMode | bool | `true` | Refuse to start while the database schema is missing tables or columns the core needs (`SCHEMA_CHECK_STRICT_MODE`). Keep it on: it stops an upgrade before it breaks logins. See "Upgrading". |
| supertokens.telemetry | bool | `true` | Send anonymous usage telemetry to SuperTokens (`DISABLE_TELEMETRY` is set to the opposite). |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after the `preStop` hook before killing the container. |
| tolerations | list | `[]` | Tolerations. |
