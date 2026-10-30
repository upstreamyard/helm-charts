# Discourse Helm chart

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square) ![AppVersion: 2026.10.0](https://img.shields.io/badge/AppVersion-2026.10.0-informational?style=flat-square)

> **Support:** For help with setup, production issues or custom changes, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for [Discourse](https://github.com/discourse/discourse), the open-source community forum. It uses the [`upstreamyard/discourse`](https://github.com/upstreamyard/discourse) image, which runs one process per container.

> Community chart by **upstreamyard**, not an official Discourse chart. Discourse is © Civilized Discourse Construction Kit, Inc., licensed under GPL-2.0-or-later; "Discourse" is a registered trademark of Civilized Discourse Construction Kit, Inc.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install discourse upstreamyard/discourse \
  --set discourse.hostname=forum.example.com \
  --set discourse.secretKeyBase=$(openssl rand -hex 64) \
  --set database.host=your-postgres --set database.password='...' \
  --set redis.host=your-redis
```

Or from the OCI registry:

```bash
helm install discourse oci://ghcr.io/upstreamyard/charts/discourse --set discourse.hostname=forum.example.com ...
```

Then create the first admin account (it asks for email and password):

```bash
kubectl exec -it deploy/discourse -- rake admin:create
```

Served over HTTPS (Ingress with TLS)? Turn on Admin > Settings > Security > "force https", or run `kubectl exec deploy/discourse -- rails runner 'SiteSetting.force_https = true'`. Without it Discourse generates `http://` links.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install discourse upstreamyard/discourse --verify --keyring upstreamyard.gpg --set ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **PostgreSQL 18 with the pgvector extension** (required). The `pgvector/pgvector:pg18` image is Postgres 18 with pgvector included; managed services (RDS, Cloud SQL, Azure) offer it too. Without pgvector the migrations fail with `extension "vector" is not available`, because the bundled Discourse AI plugin needs it. The user needs the right to create extensions on first install.
- **Redis 7** (required), with persistence and no key eviction (`maxmemory-policy noeviction`). Discourse uses database `redis.db` and the next one.
- **An SMTP server** for sign-up, password reset and notification emails.
- A default StorageClass, or `persistence.*.storageClass`, for the uploads and backups volumes.

This chart does not deploy a database or Redis.

## What the chart does

- **Migrations:** in two Jobs, as Discourse splits them. Before every install and upgrade, a Job runs the regular migrations, which only add to the schema, so pods of the old version keep working. After the new pods are ready, a second Job runs the post-deployment migrations, which remove what the old version still used. The web pods start with `MIGRATE_ON_BOOT=0`. Set `migrations.enabled=false` to run all migrations on pod startup instead.
- **Background jobs:** by default every web pod also runs one Sidekiq process (emails, notifications, scheduled tasks). Set `sidekiq.enabled=true` for a separate Sidekiq Deployment that scales on its own.
- **Storage:** PersistentVolumeClaims for uploads and backups, kept when the release is uninstalled. With the default ReadWriteOnce volumes the chart runs one web pod and replaces it on upgrades (`Recreate`, brief downtime); more pods or a separate Sidekiq need ReadWriteMany volumes (or S3), and installing without them fails with an error.
- **Probes:** `/srv/status` for startup, liveness and readiness of the web pods. The Sidekiq pods are restarted when Sidekiq stops sending its heartbeat to Redis (`sidekiq-alive` in the image; it fails about 60 s into a hang, then after 3 failed checks).
- **Graceful shutdown:** on `SIGTERM` the web server finishes requests in flight; `terminationGracePeriodSeconds: 40` is above its 30 s request timeout.
- **Security:** runs as non-root UID 10001 with `fsGroup` 10001 for the volumes, drops all capabilities, and doesn't mount a ServiceAccount token. Discourse writes to its app directory, so the root filesystem stays writable.
- **`helm test`** checks `/srv/status` and that the home page answers (it needs the database) through the Service.

## Configuration

Every Discourse setting from [`config/discourse_defaults.conf`](https://github.com/discourse/discourse/blob/main/config/discourse_defaults.conf) can be set as `DISCOURSE_<SETTING>` through `extraEnv` (plain values) or `extraEnvFrom` (Secrets). Forum settings (title, login methods, categories, …) live in the database and are changed in the admin UI.

Plugins: the image contains the plugins bundled with Discourse (chat, Discourse AI, solved, reactions, …); enable them in the admin UI. Third-party plugins are not supported yet.

## Production example

```yaml
# values-prod.yaml
discourse:
  hostname: forum.example.com
  existingSecret: discourse          # key: secret-key-base (openssl rand -hex 64)
  notificationEmail: forum@example.com
database:
  host: postgres.example.internal
  existingSecret: discourse-db       # key: database-password
redis:
  host: redis.example.internal
smtp:
  address: smtp.example.com
  username: forum@example.com
  existingSecret: discourse-smtp     # key: smtp-password
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 20m
  hosts:
    - host: forum.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - hosts: [forum.example.com]
      secretName: forum-tls
```

For several web pods and a separate Sidekiq, add ReadWriteMany volumes:

```yaml
replicaCount: 2
sidekiq:
  enabled: true
persistence:
  uploads:
    accessModes: [ReadWriteMany]
    storageClass: your-rwx-class
  backups:
    accessModes: [ReadWriteMany]
    storageClass: your-rwx-class
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the database password (recommended for production). |
| database.existingSecretKey | string | `"database-password"` | Key in `existingSecret` that holds the database password. |
| database.host | string | `""` | PostgreSQL host. Required. |
| database.name | string | `"discourse"` | Database name. |
| database.password | string | `""` | Database password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| database.port | int | `5432` | PostgreSQL port. |
| database.username | string | `"discourse"` | Database user. |
| discourse.developerEmails | string | `""` | Comma-separated emails that Discourse makes admins when they sign up (`DISCOURSE_DEVELOPER_EMAILS`). Optional; the first admin can also be created with `rake admin:create`. |
| discourse.existingSecret | string | `""` | Name of an existing Secret that holds the secret key base. |
| discourse.existingSecretKey | string | `"secret-key-base"` | Key in `existingSecret` that holds the secret key base. |
| discourse.hostname | string | `""` | Public hostname of the forum (`DISCOURSE_HOSTNAME`), used in links and emails. Required. |
| discourse.notificationEmail | string | `""` | Sender address of Discourse's emails (`DISCOURSE_NOTIFICATION_EMAIL`). |
| discourse.secretKeyBase | string | `""` | Secret used to sign sessions and cookies (`DISCOURSE_SECRET_KEY_BASE`), e.g. from `openssl rand -hex 64`. Required unless `existingSecret` is set. Stored in a Secret created by this chart. |
| extraEnv | list | `[]` | Extra environment variables for all Discourse containers, e.g. any `DISCOURSE_<SETTING>` from Discourse's `config/discourse_defaults.conf` (https://github.com/discourse/discourse/blob/main/config/discourse_defaults.conf). |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Discourse containers. |
| extraVolumes | list | `[]` | Extra volumes for the web and Sidekiq pods. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"upstreamyard/discourse"` | Image repository. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. Allow request bodies as large as your upload limit, e.g. `nginx.ingress.kubernetes.io/proxy-body-size: 20m`. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"forum.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. The host should match `discourse.hostname`. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/srv/status","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on `/srv/status`. |
| migrations.activeDeadlineSeconds | int | `1800` | Maximum runtime of each migration Job in seconds. |
| migrations.backoffLimit | int | `3` | Retries of each migration Job before the install/upgrade fails. |
| migrations.enabled | bool | `true` | Run migrations in Jobs (Helm hooks) and disable migrations on pod startup: regular migrations before every install and upgrade, post-deployment migrations (which remove old columns) after it. If false, every web pod runs all migrations on startup (safe for concurrent pods, Discourse locks them). |
| migrations.resources | object | `{"limits":{"memory":"1536Mi"},"requests":{"cpu":"100m","memory":"768Mi"}}` | Resources for the migration Jobs. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.backups.accessModes | list | `["ReadWriteOnce"]` | Access modes. Use `[ReadWriteMany]` for more than one pod. |
| persistence.backups.enabled | bool | `true` | Persist backups (`public/backups`). |
| persistence.backups.existingClaim | string | `""` | Use an existing PersistentVolumeClaim. |
| persistence.backups.size | string | `"10Gi"` | Volume size. |
| persistence.backups.storageClass | string | `""` | Storage class. Empty uses the cluster default. |
| persistence.uploads.accessModes | list | `["ReadWriteOnce"]` | Access modes. Use `[ReadWriteMany]` for more than one pod. |
| persistence.uploads.enabled | bool | `true` | Persist uploads (`public/uploads`). Disable only when uploads go to S3 (configure it with `extraEnv`). |
| persistence.uploads.existingClaim | string | `""` | Use an existing PersistentVolumeClaim. |
| persistence.uploads.size | string | `"10Gi"` | Volume size. |
| persistence.uploads.storageClass | string | `""` | Storage class. Empty uses the cluster default. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":10001,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as non-root UID 10001; `fsGroup` makes the volumes writable. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/srv/status","port":"http"},"periodSeconds":5,"timeoutSeconds":3}` | Readiness probe on `/srv/status`. |
| redis.db | int | `0` | Redis database number. Discourse uses this one and the next one (for Sidekiq). |
| redis.existingSecret | string | `""` | Name of an existing Secret that holds the Redis password. |
| redis.existingSecretKey | string | `"redis-password"` | Key in `existingSecret` that holds the Redis password. |
| redis.host | string | `""` | Redis host. Required. |
| redis.password | string | `""` | Redis password, if any. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| redis.port | int | `6379` | Redis port. |
| replicaCount | int | `1` | Number of web pods. More than 1 needs uploads and backups on ReadWriteMany volumes (or S3). |
| resources | object | `{"limits":{"memory":"3Gi"},"requests":{"cpu":"500m","memory":"1536Mi"}}` | Resources for the web container (includes one Sidekiq process when `sidekiq.enabled` is false). |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Container security context. Discourse writes to its app directory, so the root filesystem stays writable. |
| service.port | int | `80` | Service port. Discourse listens on 3000 inside the container. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Discourse does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| sidekiq.concurrency | int | `5` | Threads per Sidekiq process (`DISCOURSE_SIDEKIQ_WORKERS`). |
| sidekiq.enabled | bool | `false` | Run Sidekiq (background jobs, emails, scheduled tasks) in its own Deployment. If false, every web pod runs one Sidekiq process (`UNICORN_SIDEKIQS=1`). True needs ReadWriteMany volumes or S3, since Sidekiq also writes uploads and backups. |
| sidekiq.livenessProbe | object | `{"exec":{"command":["sidekiq-alive"]},"failureThreshold":3,"periodSeconds":30,"timeoutSeconds":10}` | Liveness probe: fails when Sidekiq stopped sending its heartbeat to Redis (after about 60 s), so a hung Sidekiq is restarted after 3 failed checks. |
| sidekiq.replicaCount | int | `1` | Sidekiq pods. |
| sidekiq.resources | object | `{"limits":{"memory":"1536Mi"},"requests":{"cpu":"100m","memory":"768Mi"}}` | Resources for the Sidekiq container. |
| sidekiq.startupProbe | object | `{"exec":{"command":["sidekiq-alive"]},"failureThreshold":18,"periodSeconds":10,"timeoutSeconds":10}` | Startup probe: waits for Sidekiq's first heartbeat in Redis (`sidekiq-alive` in the image). |
| smtp.address | string | `""` | SMTP server. Leave empty to not configure email. |
| smtp.enableStartTls | bool | `true` | Use STARTTLS. |
| smtp.existingSecret | string | `""` | Name of an existing Secret that holds the SMTP password. |
| smtp.existingSecretKey | string | `"smtp-password"` | Key in `existingSecret` that holds the SMTP password. |
| smtp.password | string | `""` | SMTP password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| smtp.port | int | `587` | SMTP port. |
| smtp.username | string | `""` | SMTP user name. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/srv/status","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Startup probe on `/srv/status`. Boot takes about 20 s without migrations. |
| terminationGracePeriodSeconds | int | `40` | Seconds Kubernetes waits after SIGTERM. The web server finishes requests in flight (request timeout 30 s). |
| tolerations | list | `[]` | Tolerations. |
| web.workers | int | `2` | Web worker processes per pod (`UNICORN_WORKERS`). Each needs roughly 250-300 MiB of memory. |
