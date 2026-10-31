# Electric Helm chart

![Version: 0.1.3](https://img.shields.io/badge/Version-0.1.3-informational?style=flat-square) ![AppVersion: 1.8.1](https://img.shields.io/badge/AppVersion-1.8.1-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for the [Electric](https://github.com/electric-sql/electric) sync engine. Electric reads changes from PostgreSQL through logical replication and syncs subsets of your tables ("shapes") to web and mobile apps over HTTP, so each client keeps a live local copy. It uses Electric's official image [`electricsql/electric`](https://hub.docker.com/r/electricsql/electric).

> Community chart by **upstreamyard**, not an official ElectricSQL chart. Electric is licensed under Apache-2.0.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install electric upstreamyard/electric \
  --set electric.secret=$(openssl rand -hex 32) \
  --set database.url='postgresql://electric:password@your-postgres:5432/app'
```

Or from the OCI registry:

```bash
helm install electric oci://ghcr.io/upstreamyard/charts/electric --set electric.secret=... --set database.url=...
```

Then request a shape, with the secret, from your backend or auth proxy:

```bash
curl "http://electric.<namespace>.svc.cluster.local:3000/v1/shape?table=items&offset=-1&secret=<your secret>"
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install electric upstreamyard/electric --verify --keyring upstreamyard.gpg --set ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **PostgreSQL 14 or newer** with `wal_level = logical`. This chart is tested with PostgreSQL 18. It does not deploy a database. Managed PostgreSQL services have their own switch for logical replication.
- **A database role for Electric** with `LOGIN` and `REPLICATION`, `CREATE` on the database (Electric creates its publication on first start) and ownership of every table you sync. We tested each: without `CREATE` the pod crash-loops with `Publication "electric_publication_…" not found`, and a shape for a table the role doesn't own fails with `must be owner of table`. If your role may not own the tables, set `ELECTRIC_MANUAL_TABLE_PUBLISHING=true` in `extraEnv` and add tables to the publication yourself, see Electric's [configuration reference](https://electric.ax/docs/sync/api/config#electric-manual-table-publishing).
- **A direct connection** for `database.url`: logical replication doesn't work through most connection poolers. Ordinary queries can go through a pooler with `database.pooledUrl`.
- **Connections:** Electric opens a pool of 20 connections (`ELECTRIC_DB_POOL_SIZE`) plus its replication connection. Make sure `max_connections` leaves room.
- **An auth proxy** (recommended): Electric can't decide which user may see which rows. Clients should call your backend, which checks the user, adds the secret and the allowed `table`/`where` and forwards to Electric. See Electric's [auth guide](https://electric.ax/docs/sync/guides/auth).

## What the chart does

- **One pod:** Electric runs as a single active instance per replication slot, coordinated by a PostgreSQL advisory lock, so the chart always runs one replica.
- **Secret required:** the chart refuses to install without `electric.secret` or `electric.existingSecret`. Without it, anyone who can reach the Service can read every table Electric's role can read. `electric.insecure: true` turns this off for development; `helm test` then skips the secret check. Changing the secret restarts the pod.
- **Persistent shape storage:** shape logs and metadata go to a PersistentVolumeClaim mounted at `/var/lib/electric/data`. They survive restarts: in our tests a client resumed its shape after a pod restart and after an upgrade from 1.8.0 to 1.8.1 and received only the new rows. The claim is kept on `helm uninstall` (`persistence.keep`) so a reinstall continues where it left off.
- **Without persistence** (`persistence.enabled: false`) Electric stores shapes in an emptyDir and the chart switches it to a temporary replication slot with a random name. PostgreSQL drops the slot when the pod stops, so no slot is left behind to hold WAL. The cost: every restart makes all clients re-fetch their shapes.
- **Probes:** `/v1/health` answers 202 while Electric starts or waits for the replication lock and 200 once active. Startup and liveness accept both. Readiness depends on the rollout strategy, see [Storage and upgrades](#storage-and-upgrades). During a PostgreSQL outage in our test, the pod became not ready, stayed running without restarts and turned active again by itself once PostgreSQL was back.
- **Configuration:** every Electric option is an environment variable; the chart sets the connection, secret, storage, replication stream ID, log level and metrics, and you add others with `extraEnv`. Logs go to stdout without colour codes.
- **Metrics:** `metrics.enabled` exposes Prometheus metrics on port 9090 (`/metrics`), and `metrics.serviceMonitor.enabled` adds a ServiceMonitor. Only enable them with a scraper: Electric buffers unscraped metrics in memory without limit.
- **Security:** runs as UID 10001 with a read-only root filesystem (Electric's start script writes its runtime config to an emptyDir at `/tmp`), drops all capabilities and doesn't mount a ServiceAccount token.
- **`helm test`** checks that Electric is active, refuses a shape request without the secret (401), and with it looks the table up in PostgreSQL (400 for a table that doesn't exist).

## Storage and upgrades

How the pod is replaced on `helm upgrade` depends on whether old and new pod can mount the volume at the same time:

| Storage (`persistence.accessModes`) | Rollout | Readiness | Measured in our tests |
|---|---|---|---|
| `ReadWriteOnce` (default) | `Recreate`: old pod stops, then the new one starts | only when active (200) | about 7 seconds without service; clients retry and resume their shapes |
| `ReadWriteMany` | `RollingUpdate`: new pod starts first, takes over the lock when the old one stops | 202 or 200 | no failed request for existing or new shapes |

With `ReadWriteMany`, the new pod serves existing shapes read-only while the old pod still holds the lock; requests that would create a new shape get a 503 with `Retry-After`, which Electric's TypeScript client retries. The chart also sets `ELECTRIC_SHAPE_DB_EXCLUSIVE_MODE=true`, which Electric requires on network filesystems. Note that network filesystems (NFS, EFS) are much slower than local disks for Electric's IO-heavy storage.

Set `rolloutStrategy` to override the choice, e.g. `RollingUpdate` with an `existingClaim` you know is shared.

**Keep storage and slot together.** The shape data on the volume and the replication slot in PostgreSQL belong together. If you switch to a different database, change `electric.replicationStreamId`, or delete the volume, clean up the other side by hand: drop the old slot and publication (`electric_slot_<id>`, `electric_publication_<id>`) so they don't keep PostgreSQL from removing WAL, or delete the old volume.

## Production example

```yaml
# values-prod.yaml
electric:
  existingSecret: electric               # key: electric-secret
  replicationStreamId: myapp
database:
  existingSecret: electric-db            # key: database-url
  existingSecretPooledUrlKey: pooled-url # optional, through PgBouncer
persistence:
  storageClass: fast-local-ssd
  size: 50Gi
resources:
  requests: { cpu: "1", memory: 1Gi }
  limits: { memory: 4Gi }
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

## Known issues

- **Replication stream ID:** only lower-case letters, digits and underscores. Electric 1.8.1 refuses to start with a hyphen (`Invalid unquoted identifier contains special characters`), although Electric's upgrading guide uses `deploy-blue` as an example. The chart's schema rejects such IDs.
- **WAL growth:** while Electric is stopped, its replication slot keeps PostgreSQL from removing WAL. Don't leave a release scaled down or broken for long, and drop the slot when you uninstall Electric for good.
- At startup the log shows `Failed open sctp dynamic library: libsctp.so.1`. It's harmless: the image doesn't ship an optional library the Erlang runtime looks for.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the connection URL(s) (recommended for production). |
| database.existingSecretKey | string | `"database-url"` | Key in `existingSecret` that holds the connection URL. |
| database.existingSecretPooledUrlKey | string | `""` | Key in `existingSecret` that holds the pooled connection URL. Empty: no pooled URL. |
| database.pooledUrl | string | `""` | Optional URL for all queries except replication, e.g. through PgBouncer (`ELECTRIC_POOLED_DATABASE_URL`). Empty uses `url`. Ignored when `existingSecret` is set. |
| database.url | string | `""` | Connection URL, e.g. `postgresql://electric:password@postgres:5432/app` (`DATABASE_URL`). Used for logical replication, so it must reach PostgreSQL directly, not through a connection pooler. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| electric.existingSecret | string | `""` | Name of an existing Secret that holds the API secret. |
| electric.existingSecretKey | string | `"electric-secret"` | Key in `existingSecret` that holds the API secret. |
| electric.insecure | bool | `false` | Run without an API secret (`ELECTRIC_INSECURE`). Anyone who can reach the Service can then read any table Electric's database role can read. Only for development. |
| electric.logLevel | string | `""` | Log level (`ELECTRIC_LOG_LEVEL`): `error`, `warning`, `info` or `debug`. Empty keeps Electric's default (`info`). |
| electric.replicationStreamId | string | `""` | Suffix of the replication slot and publication names in PostgreSQL (`ELECTRIC_REPLICATION_STREAM_ID`), e.g. `myapp` gives `electric_slot_myapp`. Empty uses Electric's default `default`. Each Electric installation on the same database needs its own. |
| electric.secret | string | `""` | Secret that every shape request must carry (`ELECTRIC_SECRET`), usually added by your auth proxy, never by browsers. E.g. from `openssl rand -hex 32`. Stored in a Secret created by this chart. Required unless `existingSecret` is set or `insecure` is true. |
| extraEnv | list | `[]` | Extra environment variables. Every Electric option is an environment variable, e.g. `ELECTRIC_MANUAL_TABLE_PUBLISHING`, `ELECTRIC_OTLP_ENDPOINT`, `ELECTRIC_DB_POOL_SIZE`. See https://electric.ax/docs/sync/api/config |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Electric container. |
| extraVolumes | list | `[]` | Extra volumes for the pod, e.g. a CA certificate for `ELECTRIC_DATABASE_CA_CERTIFICATE_FILE`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"electricsql/electric"` | Image repository. Electric's official image. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. Long-poll requests stay open for up to 20 seconds, so keep the proxy's read timeout above that. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. Clients usually reach Electric through your auth proxy or CDN, not directly. |
| ingress.hosts | list | `[{"host":"electric.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/v1/health","port":"http"},"periodSeconds":10,"timeoutSeconds":3}` | Liveness probe on `/v1/health` (200 or 202). |
| metrics.enabled | bool | `false` | Expose Prometheus metrics on `/metrics` (`ELECTRIC_PROMETHEUS_PORT`). Only enable it if something scrapes it: unscraped, Electric buffers metrics in memory without limit. |
| metrics.port | int | `9090` | Port of the metrics endpoint, on the pod and the Service. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a ServiceMonitor for the Prometheus Operator. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the one your Prometheus selects ServiceMonitors by. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes of the claim. With `ReadWriteMany`, upgrades roll over without downtime (see `rolloutStrategy`). |
| persistence.annotations | object | `{}` | Annotations for the claim. |
| persistence.enabled | bool | `true` | Store shape data on a PersistentVolumeClaim. If false, an emptyDir is used and Electric uses a temporary replication slot, so every restart makes all clients re-fetch their shapes. |
| persistence.existingClaim | string | `""` | Use an existing PersistentVolumeClaim instead of creating one. Set `accessModes` to match it, since they pick the rollout strategy. |
| persistence.keep | bool | `true` | Keep the claim when the release is uninstalled (`helm.sh/resource-policy: keep`), so shape data and the replication slot stay in step after a reinstall. |
| persistence.size | string | `"10Gi"` | Size of the claim. How much Electric needs depends on your shapes and write volume. |
| persistence.storageClass | string | `""` | StorageClass for the claim. Empty uses the cluster's default. Electric is disk-heavy: prefer fast local SSDs. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":10001,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image has no user of its own, so the chart picks UID 10001. |
| readinessProbe | object | `{}` | Readiness probe. Empty picks one that matches the rollout strategy. With `Recreate`, the pod is ready only once `/v1/health` returns 200 (active). With `RollingUpdate` it accepts 202 too, because the new pod can't become active while the old one still holds the replication lock. |
| resources | object | `{"limits":{"memory":"2Gi"},"requests":{"cpu":"250m","memory":"512Mi"}}` | Resources for the Electric container. Electric used about 260 MiB idle in our tests; memory grows with the number of active shapes. |
| rolloutStrategy | string | `""` | How the pod is replaced on upgrades: `Recreate` or `RollingUpdate`. Empty picks `RollingUpdate` (start the new pod before stopping the old one) when `persistence.accessModes` includes `ReadWriteMany`, otherwise `Recreate`. `RollingUpdate` needs storage both pods can mount at once. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. Electric's runtime files go to an emptyDir, so the root filesystem is read-only. |
| service.port | int | `3000` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Electric does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/v1/health","port":"http"},"periodSeconds":5,"timeoutSeconds":3}` | Startup probe on `/v1/health`. Electric answers 202 while it loads shapes and 200 once active; both count as started. |
| terminationGracePeriodSeconds | int | `60` | Seconds Kubernetes waits for Electric to stop before killing it. Electric stopped in under a second in our tests. |
| tolerations | list | `[]` | Tolerations. |
