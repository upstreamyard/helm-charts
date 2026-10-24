# Saleor Helm chart

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square) ![AppVersion: 3.23.44](https://img.shields.io/badge/AppVersion-3.23.44-informational?style=flat-square)

Helm chart for [Saleor](https://github.com/saleor/saleor), the headless GraphQL commerce platform. It runs the GraphQL API, the Celery worker and beat for background tasks, and the [Saleor dashboard](https://github.com/saleor/saleor-dashboard), using Saleor's official images `ghcr.io/saleor/saleor` and `ghcr.io/saleor/saleor-dashboard`.

> Community chart by **upstreamyard**, not an official Saleor chart. Saleor is © Saleor Commerce, licensed under BSD-3-Clause.

## Install

Saleor needs PostgreSQL, a Celery broker (e.g. Redis) and two S3 buckets (see [Requirements](#requirements)). Create the keys once and keep them; the RSA key signs login tokens, so a new key logs everyone out:

```bash
kubectl create secret generic saleor-keys \
  --from-literal=secret-key="$(openssl rand -hex 32)" \
  --from-literal=rsa-private-key="$(openssl genrsa 2048)"

helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install saleor upstreamyard/saleor \
  --set saleor.publicUrl=https://api.example.com/ \
  --set 'saleor.allowedClientHosts={shop.example.com,dashboard.example.com}' \
  --set saleor.existingSecret=saleor-keys \
  --set database.url='postgres://saleor:...@your-postgres:5432/saleor' \
  --set celery.brokerUrl=redis://your-redis:6379/1 \
  --set cache.url=redis://your-redis:6379/0 \
  --set storage.s3.mediaBucket=your-media-bucket \
  --set storage.s3.privateBucket=your-private-bucket \
  --set storage.s3.region=eu-central-1 \
  --set admin.email=you@example.com --set admin.password='...'
```

Or from the OCI registry:

```bash
helm install saleor oci://ghcr.io/upstreamyard/charts/saleor --set saleor.publicUrl=https://api.example.com/ ...
```

The API answers on `/graphql/`, the dashboard on `/dashboard/` of its own Service (or `dashboard.ingress`). Without `admin.*`, create the first admin account with `kubectl exec -it deploy/saleor -- python3 manage.py createsuperuser`.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install saleor upstreamyard/saleor --verify --keyring upstreamyard.gpg --set ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **PostgreSQL** (required). Saleor 3.23.41 was tested with PostgreSQL 17 and 18; Saleor's own CI uses 15. The database user must be allowed to create tables and indexes (migrations).
- **A Celery broker** (required): Redis, RabbitMQ or Amazon SQS. Webhooks, search indexing, emails and data migrations run as background tasks.
- **Redis as a cache** (recommended with more than one pod), in a different Redis database than the broker.
- **Object storage** (required): two S3 buckets, or Google Cloud Storage or Azure. The media bucket (product images, thumbnails) must be readable by browsers; the private bucket (webhook payloads, exports) must not be public. Saleor doesn't serve files from local disk in production, and the API writes files the worker reads, so a local volume doesn't work.

This chart does not deploy a database, Redis or object storage.

## What the chart does

- **Production mode:** runs Saleor with `DEBUG=False`. `ALLOWED_HOSTS` is the host of `saleor.publicUrl` plus the Service's cluster DNS names, so other pods can call `http://<release>-saleor:8000/graphql/`.
- **Migrations:** a Job runs `manage.py migrate` before every install and upgrade (Helm hook), then creates the admin account from `admin.*` if it doesn't exist yet. Saleor's pods don't migrate on startup.
- **Data migrations on upgrades:** `migrate` also queues Celery tasks that migrate data. Celery discards tasks it doesn't know, so the old version's workers, which still run while the Job runs, would drop the new version's tasks. Without the steps below, a 3.22 → 3.23 upgrade lost 7 of these tasks. The chart therefore:
  - sends them to a queue named after the new version, which only the new workers consume;
  - replaces the workers with `Recreate`.

  Tested: no task was lost on a 3.22.73 → 3.23.41 upgrade.
- **Background tasks:** a Celery worker Deployment (`worker.*`) and exactly one Celery beat with Saleor's database scheduler (`beat.*`, `Recreate`). The worker's liveness probe pings it over the broker and restarts a hung worker after 3 failed checks.
- **Dashboard:** the official dashboard image, configured with `API_URL` (defaults to `saleor.publicUrl` + `graphql/`). The chart runs its nginx as non-root on port 8080 with its own config, serving `/dashboard/`.
- **Probes and shutdown:** `/health/` for startup, liveness and readiness. On rollouts, a 10 s `preStop` sleep keeps a stopping API pod serving until it has left the Service, then the server finishes requests in flight (up to 30 s). Tested: 0 failed requests out of 1546 during a rollout, compared with 5 out of 1030 without the sleep.
- **Security:** runs as non-root (the image's `saleor` user, UID 999; nginx UID 101), read-only root filesystem, drops all capabilities, no ServiceAccount token. Secrets come from a Secret created by the chart or from your own (`existingSecret` for every credential).
- **`helm test`** checks `/health/`, runs a GraphQL query (needs the database) through the Service, and checks that the dashboard serves the configured API URL.

## Configuration

Every Saleor setting is an environment variable; set them with `extraEnv` (plain values) or `extraEnvFrom` (Secrets). See Saleor's [list of environment variables](https://docs.saleor.io/setup/configuration). Shop settings (channels, taxes, shipping, payment and email plugins) live in the database and are changed in the dashboard.

- **Apps and webhooks inside the cluster:** Saleor refuses to call private IP addresses (protection against server-side request forgery), so webhooks to apps in the same cluster fail with `Invalid IP address`. Set `HTTP_IP_FILTER_ENABLED=False` with `extraEnv` if you run Saleor apps in the cluster.
- **Calling the API over http from inside the cluster:** when `saleor.publicUrl` is `https`, Saleor redirects plain-http requests to https (`301`). In-cluster clients such as a storefront doing server-side rendering must send `X-Forwarded-Proto: https`. The Ingress controller sends it for outside traffic.
- **Email:** Saleor sends emails through its email plugins (configured in the dashboard) or through apps; `USER_EMAIL_URL` can provide the SMTP settings for the user emails plugin.
- **Google Cloud Storage or Azure:** set `storage.type=custom` and the `GS_*` or `AZURE_*` variables (media and private bucket or container) with `extraEnv`/`extraEnvFrom`. Not tested by us; S3 was tested with an S3-compatible store (SeaweedFS).
- **Credentials for S3 from a cloud identity** (e.g. EKS IAM roles for service accounts): leave `storage.s3.accessKeyId` and `existingSecret` empty and annotate the ServiceAccount (`serviceAccount.annotations`); boto3 then uses its default credential chain. Not tested by us.
- **Separate task queues:** if you route tasks to other queues with Saleor's `*_QUEUE_NAME` settings, add them to `worker.queues`.

## Production example

```yaml
# values-prod.yaml
replicaCount: 2
saleor:
  publicUrl: https://api.shop.example.com/
  allowedClientHosts: [shop.example.com, dashboard.shop.example.com]
  allowedGraphqlOrigins: [https://shop.example.com, https://dashboard.shop.example.com]
  existingSecret: saleor-keys        # keys: secret-key, rsa-private-key
database:
  existingSecret: saleor-db          # key: database-url
celery:
  existingSecret: saleor-redis       # key: broker-url
cache:
  existingSecret: saleor-redis       # key: cache-url
storage:
  s3:
    mediaBucket: shop-media
    privateBucket: shop-private
    region: eu-central-1
    customDomain: media.shop.example.com   # CDN in front of the media bucket
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/saleor-s3
worker:
  replicaCount: 2
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 20m
  hosts:
    - host: api.shop.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - hosts: [api.shop.example.com]
      secretName: api-tls
dashboard:
  ingress:
    enabled: true
    className: nginx
    hosts:
      - host: dashboard.shop.example.com
        paths: [{ path: /, pathType: Prefix }]
    tls:
      - hosts: [dashboard.shop.example.com]
        secretName: dashboard-tls
```

## Known issues

- **A fresh install of Saleor 3.22.73 fails on PostgreSQL 18** (migration `discount.0052_drop_sales_constraints`: `column "id" is in a primary key`). 3.23.41 installs fine on PostgreSQL 18.
- **The dashboard image is released separately** from the API. The chart pins a dashboard version with the same minor version as the API; override `dashboard.image.tag` to change it.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admin.email | string | `""` | Email of the first admin account. Leave empty to create it yourself (see the README). |
| admin.existingSecret | string | `""` | Name of an existing Secret that holds the admin password. |
| admin.existingSecretKey | string | `"admin-password"` | Key in `existingSecret` that holds the admin password. |
| admin.password | string | `""` | Password of the first admin account. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| affinity | object | `{}` | Affinity. |
| beat.enabled | bool | `true` | Run Celery beat, the scheduler for periodic tasks (expiring checkouts and orders, search index updates, cleanup). Exactly one runs. |
| beat.resources | object | `{"limits":{"memory":"384Mi"},"requests":{"cpu":"20m","memory":"192Mi"}}` | Resources for the beat container. |
| cache.existingSecret | string | `""` | Name of an existing Secret that holds the cache URL. |
| cache.existingSecretKey | string | `"cache-url"` | Key in `existingSecret` that holds the cache URL. |
| cache.url | string | `""` | Cache URL (`CACHE_URL`), e.g. `redis://redis:6379/0`. Use a different Redis database than the broker. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| celery.brokerUrl | string | `""` | Broker URL (`CELERY_BROKER_URL`), e.g. `redis://redis:6379/1`. Redis, RabbitMQ (`amqp://`) and SQS (`sqs://`) work. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| celery.existingSecret | string | `""` | Name of an existing Secret that holds the broker URL. |
| celery.existingSecretKey | string | `"broker-url"` | Key in `existingSecret` that holds the broker URL. |
| dashboard.apiUrl | string | `""` | GraphQL URL the dashboard calls from the browser (`API_URL`). Defaults to `saleor.publicUrl` + `graphql/`. |
| dashboard.enabled | bool | `true` | Deploy the Saleor dashboard (the admin UI, a static web app). |
| dashboard.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| dashboard.image.repository | string | `"ghcr.io/saleor/saleor-dashboard"` | Dashboard image repository. |
| dashboard.image.tag | string | `"3.23.41"` | Dashboard image tag. Released separately from the API; keep its minor version equal to the API's. |
| dashboard.ingress.annotations | object | `{}` | Ingress annotations. |
| dashboard.ingress.className | string | `""` | Ingress class name. |
| dashboard.ingress.enabled | bool | `false` | Create an Ingress for the dashboard. It is served under `/dashboard/`. |
| dashboard.ingress.hosts | list | `[{"host":"dashboard.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. Add the host to `saleor.allowedClientHosts`. |
| dashboard.ingress.tls | list | `[]` | Ingress TLS configuration. |
| dashboard.podSecurityContext | object | `{"fsGroup":101,"runAsGroup":101,"runAsNonRoot":true,"runAsUser":101,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. nginx runs as non-root UID 101. |
| dashboard.replicaCount | int | `1` | Dashboard pods. |
| dashboard.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources for the dashboard container. |
| dashboard.securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| dashboard.service.port | int | `80` | Service port. The dashboard listens on 8080 inside the container. |
| dashboard.service.type | string | `"ClusterIP"` | Service type. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the connection URL (recommended for production). |
| database.existingSecretKey | string | `"database-url"` | Key in `existingSecret` that holds the connection URL. |
| database.url | string | `""` | Connection URL (`DATABASE_URL`), e.g. `postgres://saleor:password@postgres:5432/saleor`. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| extraEnv | list | `[]` | Extra environment variables for the API, worker, beat and migration containers, e.g. any Saleor setting such as `DATABASE_URL_REPLICA`, `DEFAULT_COUNTRY` or `SENTRY_DSN`. |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Saleor containers. |
| extraVolumes | list | `[]` | Extra volumes for the API, worker, beat and migration pods. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/saleor/saleor"` | Image repository of the Saleor API, also used for the Celery worker, beat and the migration Job. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. Allow request bodies as large as your image uploads, e.g. `nginx.ingress.kubernetes.io/proxy-body-size: 20m`. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the API. |
| ingress.hosts | list | `[{"host":"api.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. The host should match `saleor.publicUrl`. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| lifecycle | object | `{"preStop":{"exec":{"command":["sleep","10"]}}}` | Lifecycle hooks of the API container. The `preStop` sleep keeps a stopping pod serving until it is removed from the Service's endpoints; without it some requests fail during rollouts. |
| livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/health/","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on `/health/`. |
| migrations.activeDeadlineSeconds | int | `1800` | Maximum runtime of the migration Job in seconds. |
| migrations.backoffLimit | int | `2` | Retries of the migration Job before the install/upgrade fails. |
| migrations.enabled | bool | `true` | Run `manage.py migrate` in a Job (Helm hook) before every install and upgrade. Saleor's pods don't migrate on startup, so if false you must run it yourself. |
| migrations.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"384Mi"}}` | Resources for the migration Job. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":999,"runAsGroup":999,"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context for the API, worker, beat and migration pods. The image's `saleor` user is UID 999. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health/","port":"http"},"periodSeconds":5,"timeoutSeconds":3}` | Readiness probe on `/health/`. |
| replicaCount | int | `1` | Number of API pods. |
| resources | object | `{"limits":{"memory":"1536Mi"},"requests":{"cpu":"250m","memory":"768Mi"}}` | Resources for the API container (two server processes). |
| saleor.allowedClientHosts | list | `[]` | Hosts of your storefronts and the dashboard (`ALLOWED_CLIENT_HOSTS`). Saleor only sends users to redirect URLs on these hosts (password reset, account confirmation). Required. |
| saleor.allowedGraphqlOrigins | list | `["*"]` | Origins allowed to call the GraphQL API from a browser (CORS, `ALLOWED_GRAPHQL_ORIGINS`). |
| saleor.allowedHosts | list | `[]` | Extra hostnames the API answers to (`ALLOWED_HOSTS`). The host of `publicUrl` and the Service's cluster DNS names are always allowed. |
| saleor.existingSecret | string | `""` | Name of an existing Secret that holds the secret key and the RSA private key (recommended for production). |
| saleor.playground | bool | `true` | Serve the GraphQL Playground on `GET /graphql/` (`PLAYGROUND_ENABLED`). |
| saleor.publicUrl | string | `""` | Public URL of the API, scheme and host only, e.g. `https://api.example.com/` (`PUBLIC_URL`). Used in links Saleor generates (thumbnails, webhooks, emails). Required. |
| saleor.rsaPrivateKey | string | `""` | RSA private key in PEM format that signs the JWT access tokens (`RSA_PRIVATE_KEY`), e.g. from `openssl genrsa 2048`. All pods must share it. Required unless `existingSecret` is set. Stored in a Secret created by this chart. |
| saleor.rsaPrivateKeyKey | string | `"rsa-private-key"` | Key in `existingSecret` that holds the RSA private key. |
| saleor.secretKey | string | `""` | Django secret key (`SECRET_KEY`), e.g. from `openssl rand -hex 32`. Required unless `existingSecret` is set. Stored in a Secret created by this chart. |
| saleor.secretKeyKey | string | `"secret-key"` | Key in `existingSecret` that holds the secret key. |
| saleor.usageTelemetry | bool | `true` | Send anonymous usage data to Saleor (`SEND_USAGE_TELEMETRY`). On by default in Saleor. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The root filesystem is read-only; `/tmp` is an emptyDir. |
| service.port | int | `8000` | Service port of the API. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations, e.g. an IAM role for S3 access. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Saleor does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":40,"httpGet":{"path":"/health/","port":"http"},"periodSeconds":3,"timeoutSeconds":3}` | Startup probe on `/health/`. Boot takes about 10 s. |
| storage.s3.accessKeyId | string | `""` | Access key ID. Leave the keys and `existingSecret` empty to use the pod's cloud identity (e.g. EKS IAM roles for service accounts). Stored in a Secret created by this chart. |
| storage.s3.accessKeyIdKey | string | `"access-key-id"` | Key in `existingSecret` that holds the access key ID. |
| storage.s3.customDomain | string | `""` | Public host (and path) that serves the media bucket, e.g. a CDN (`AWS_MEDIA_CUSTOM_DOMAIN`). Needed when `endpointUrl` isn't reachable from browsers. |
| storage.s3.endpointUrl | string | `""` | Endpoint of an S3-compatible store (`AWS_S3_ENDPOINT_URL`), e.g. `http://seaweedfs-s3:8333`. Empty for Amazon S3. |
| storage.s3.existingSecret | string | `""` | Name of an existing Secret that holds the access key ID and secret access key. |
| storage.s3.mediaBucket | string | `""` | Bucket for public media (`AWS_MEDIA_BUCKET_NAME`). Objects must be readable by browsers, directly or through `customDomain`. Required. |
| storage.s3.privateBucket | string | `""` | Bucket for private files such as webhook payloads (`AWS_MEDIA_PRIVATE_BUCKET_NAME`). Must not be public. Required. |
| storage.s3.region | string | `""` | Region (`AWS_S3_REGION_NAME`). |
| storage.s3.secretAccessKey | string | `""` | Secret access key. Stored in a Secret created by this chart. |
| storage.s3.secretAccessKeyKey | string | `"secret-access-key"` | Key in `existingSecret` that holds the secret access key. |
| storage.s3.urlProtocol | string | `"https:"` | Scheme of media URLs built from `customDomain` (`AWS_S3_URL_PROTOCOL`). |
| storage.type | string | `"s3"` | `s3` for Amazon S3 or an S3-compatible store (configured below). `custom` sets nothing; configure Google Cloud Storage (`GS_*`) or Azure (`AZURE_*`) with `extraEnv` and `extraEnvFrom`. |
| terminationGracePeriodSeconds | int | `45` | Seconds Kubernetes waits after SIGTERM, including the `preStop` sleep. The API server finishes requests in flight for up to 30 s. |
| tolerations | list | `[]` | Tolerations. |
| worker.concurrency | int | `2` | Task processes per worker pod (`--concurrency`). Celery's default is one per CPU of the node. |
| worker.livenessProbe | object | `{"exec":{"command":["sh","-c","celery --app saleor.celeryconf:app inspect ping --destination celery@$HOSTNAME --timeout 10"]},"failureThreshold":3,"initialDelaySeconds":60,"periodSeconds":60,"timeoutSeconds":30}` | Liveness probe. Asks this worker for a reply over the broker; a worker that doesn't reply for 3 checks is restarted. |
| worker.queues | list | `["celery"]` | Celery queues the workers consume. Add the queues you route tasks to with Saleor's `*_QUEUE_NAME` settings. The chart adds the queue for this version's data migrations. |
| worker.replicaCount | int | `1` | Celery worker pods. They run webhooks, emails, search indexing and data migrations. |
| worker.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"512Mi"}}` | Resources for the worker container. |
| worker.terminationGracePeriodSeconds | int | `60` | Seconds Kubernetes waits after SIGTERM. Celery stops taking tasks and finishes the running ones. |
