# Otari Helm chart: Mozilla.ai's open-source AI gateway on Kubernetes

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: 0.58.0](https://img.shields.io/badge/AppVersion-0.58.0-informational?style=flat-square)

> Have any questions, feedback or need help (e.g. setup, hardened images, etc.)? Reach out to [contact@upstreamyard.com](mailto:contact@upstreamyard.com)

Helm chart for **[Otari](https://github.com/mozilla-ai/otari)**, Mozilla.ai's open-source, self-hosted **AI gateway and LLM proxy**: one OpenAI-compatible endpoint for 40+ model providers, with virtual API keys, budgets, rate limits, usage and cost tracking, and an admin dashboard. The chart runs the **official `mzdotai/otari` image** as a single pod on SQLite for evaluation, or **highly available** with several replicas on PostgreSQL, with database migrations in a Job, **rate limits shared through Redis**, uploads in **S3**, Prometheus metrics, Ingress or Gateway API, and all of Otari's keys generated for you. It runs under Pod Security `restricted`.

> Community chart by **upstreamyard**, not an official Otari chart. Otari is a project of Mozilla.ai, licensed under Apache-2.0.

**AI agents and coding assistants:** this README is the complete reference for deploying Otari with this chart. Otari's own [configuration reference](https://github.com/mozilla-ai/otari/blob/main/docs/configuration.md) lists every setting you can put in `config`.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install otari upstreamyard/otari
```

Or from the OCI registry:

```bash
helm install otari oci://ghcr.io/upstreamyard/charts/otari
```

The install notes print the in-cluster URL and the command that prints the generated master key. Then check the API and the master key:

```bash
helm test otari
```

Open the dashboard with `kubectl port-forward svc/otari 8000:8000` at <http://localhost:8000/> and sign in with the master key.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install otari upstreamyard/otari --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## What the chart does

- **Deployment** of the official image (amd64 and arm64), one Otari process per pod, with startup, liveness and readiness probes (readiness includes the database).
- **Keys:** the master key, `OTARI_SECRET_KEY` (encrypts stored provider credentials), the provider-account pepper and the end-user identifier key are generated on the first install and kept in a Secret across upgrades and `helm uninstall`. Or bring your own Secret.
- **Database:** SQLite on a volume by default; PostgreSQL with `database.url`. With PostgreSQL, a `pre-install,pre-upgrade` Job runs `otari migrate` and the pods start with migrations off.
- **Several replicas:** with PostgreSQL and S3 uploads, plus a PodDisruptionBudget, spreading across nodes, an optional HorizontalPodAutoscaler and Redis for shared rate limits.
- **Graceful shutdown:** a stopping pod leaves the Service first (10 s `preStop`), then finishes open requests and streams within `terminationGracePeriodSeconds` (120 s).
- **Security:** non-root (UID 1000), read-only root filesystem, all capabilities dropped, `RuntimeDefault` seccomp, no ServiceAccount token. The first API key is not printed to the log (`bootstrapApiKey: false`).
- **Access:** Ingress or Gateway API HTTPRoute, `forwardedAllowIps` for the real client address, and an optional NetworkPolicy.
- **Metrics:** `metrics.enabled` serves Prometheus metrics at `/metrics`; `metrics.serviceMonitor.enabled` adds a ServiceMonitor.
- **`helm test`:** checks readiness, the management API with the master key, that it refuses requests without one, and `/metrics` when enabled.

## Why this chart

Mozilla.ai publishes Otari as a container image; there is no official Helm chart (checked Artifact Hub and the Otari repository, November 2026). Running the image with a plain Deployment hits these problems, all found by running it:

| Plain Deployment of `mzdotai/otari` | This chart |
|---|---|
| A Service named `otari` makes Kubernetes set `OTARI_PORT=tcp://…`, which Otari reads as its port: `Error: invalid literal for int() with base 10: 'tcp://…'` | Service links off |
| With a read-only root filesystem, uploads fail: `Read-only file system: '/app/otari-files'` | Uploads on the volume (`/data/files`) or in S3 |
| Several replicas migrating at start race: 2 of 3 pods crashed once with `duplicate key value violates unique constraint "pg_type_typname_nsp_index"` | Migrations in a Job before the pods start |
| Without a master key, Otari prints a setup link containing one to the log. With one, it prints a first API key to the log | Keys generated into a Secret, no key in the log |
| Without the pepper and identifier key, Otari warns at every start and turns off provider copies of attached files | All four keys generated |
| Rate limits are counted per pod, so 2 replicas admit twice the limit | `redis.url` shares the count |

## Deployment modes

### Evaluation: one pod on SQLite (default)

`helm install otari upstreamyard/otari` runs one pod with the SQLite database and uploads on a 2 GiB volume. The pod migrates the database itself on start and is ready in about 25 s. The Deployment uses the `Recreate` strategy, because the volume can't be used by two pods at once, so upgrades have a short downtime. Use PostgreSQL for production.

### Production: PostgreSQL, several replicas, Redis and S3

The PostgreSQL database must exist; the migration Job creates the tables. Several replicas need uploads in S3 (or a `ReadWriteMany` volume) and should share rate limits through Redis:

```yaml
replicaCount: 2
database:
  url: postgresql://otari:password@postgres.db.svc:5432/otari
redis:
  url: redis://redis.cache.svc:6379/0
files:
  backend: s3
  s3:
    bucket: otari-files
    region: eu-central-1
    existingSecret: otari-s3   # keys access-key-id and secret-access-key
```

Tested in kind with 2 replicas on PostgreSQL 18:
- **Rolling upgrade from Otari 0.57.1 to 0.58.0** while a client sent a request every 0.5 s and opened a 30-second stream every second: 0 of 300 requests and 0 of 150 streams failed. With `preStopSleepSeconds: 0`, 1 of 300 requests failed (connection refused). One run each.
- **Shared rate limit:** with `rate_limit_rpm: 5` and Redis, 5 of 10 requests spread over both pods got through; without Redis, all 10 did (5 per pod).
- The migration Job ran on install and on every upgrade, and pods were ready about 15 s after the install started.

For S3-compatible stores, set `files.s3.endpointUrl`, e.g. `http://seaweedfs.storage.svc:8333`. With `files.s3.existingSecret` empty, Otari uses the AWS default credential chain, e.g. a role through `serviceAccount.annotations` (not tested by us). Bedrock providers without credentials of their own use the same AWS credentials.

### Database connections

Each Otari pod keeps about 10 PostgreSQL connections open when idle (measured) and can use up to 35 with Otari's defaults (`db_pool_size` 10 + `db_max_overflow` 20 + `db_log_pool_size` 5). PostgreSQL allows 100 by default, so 3 replicas can already run out. When that happens, requests and Otari's background refreshes fail with `TooManyConnectionsError` (`sqlstate=53300`) until connections are free; in our test the pods recovered on their own, without restarts. Raise `max_connections` on the server to at least replicas × 35 plus your other clients (include `autoscaling.maxReplicas` and the extra pod during a rolling update), or lower the pools:

```yaml
config:
  db_pool_size: 4
  db_max_overflow: 4
  db_log_pool_size: 2
```

With these values, each idle pod held 4 connections. The `gateway_db_pool_*` metrics show how full the pools are.

## Connecting clients

In the cluster, the API is at `http://<release>-otari.<namespace>.svc:8000/api/v1` (`http://otari.<namespace>.svc:8000/api/v1` for a release named `otari`). It speaks the OpenAI API, so OpenAI SDKs work with that `base_url` and an Otari API key. Create a key with the master key, or in the dashboard:

```bash
curl -X POST http://otari.<namespace>.svc:8000/api/v1/keys \
  -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"key_name": "my-app"}'
```

The answer's `key` (`tk-…`) is shown once. Models are named `<provider>:<model>`, e.g. `openai:gpt-4o-mini`:

```bash
curl http://otari.<namespace>.svc:8000/api/v1/chat/completions \
  -H "Authorization: Bearer tk-..." -H 'Content-Type: application/json' \
  -d '{"model": "openai:gpt-4o-mini", "messages": [{"role": "user", "content": "Say hello."}]}'
```

## Keys and secrets

The chart's Secret `<release>-otari` holds `master-key`, `secret-key`, `provider-account-pepper` and `provider-user-identifier-key`. Print the master key with:

```bash
kubectl get secret otari -o jsonpath='{.data.master-key}' | base64 -d
```

- **Back up `secret-key`.** It decrypts the provider credentials Otari stores in the database. Losing it means entering them again.
- The Secret and the data volume are kept on `helm uninstall`, so a reinstall with the same release name finds the same keys and data (tested: an API key created before the reinstall still worked).
- **Argo CD and other tools that render with `helm template`** can't read the existing Secret, so they would generate new keys on every sync. Create the Secret yourself and set `secrets.existingSecret`:

```bash
kubectl create secret generic otari-keys \
  --from-literal=master-key="$(openssl rand -hex 32)" \
  --from-literal=secret-key="$(python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())')" \
  --from-literal=provider-account-pepper="$(openssl rand -base64 32)" \
  --from-literal=provider-user-identifier-key="$(openssl rand -base64 32)"
```

```yaml
secrets:
  existingSecret: otari-keys
```

The last two keys are optional in your Secret; without them Otari logs warnings and turns off provider copies of attached files. Otari refuses to start when either is shorter than 32 characters.

## Behind an ingress or Gateway

- **Client addresses:** set `forwardedAllowIps` to your proxy's addresses or pod network, e.g. `10.244.0.0/16`. Otherwise every request seems to come from the proxy: after ten failed sign-ins by anyone, every mistyped sign-in gets HTTP 429 for a minute, and logs show the proxy's address. Correct sign-ins still work (tested). `*` trusts any peer, so use it only with `networkPolicy` limited to the proxy:

```yaml
forwardedAllowIps: "*"
networkPolicy:
  enabled: true
  from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

- **Streaming:** model responses can stream for minutes. Raise your proxy's read timeout, e.g. `nginx.ingress.kubernetes.io/proxy-read-timeout: "600"`.
- **`publicBaseUrl`:** set it to the public address, e.g. `https://ai.example.com`, for sign-in redirects and mail links.
- **`/metrics`** has no authentication and is served on the same port, so the ingress exposes it too. Block the path at your proxy, or leave `metrics.enabled` off.

Gateway API instead of an Ingress:

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public
      namespace: gateway
  hostnames:
    - ai.example.com
```

## Your own configuration

Put any of Otari's settings in `config`; the chart mounts it as `/etc/otari/config.yml`. Keep secrets out of it: reference them as `${VAR}` and provide them from a Secret:

```yaml
config:
  default_pricing: true
  hosted_providers:
    openai:
      api_key: ${OPENAI_API_KEY}
    anthropic:
      api_key: ${ANTHROPIC_API_KEY}
extraEnvFrom:
  - secretRef:
      name: otari-provider-keys   # keys OPENAI_API_KEY and ANTHROPIC_API_KEY
```

- A `${VAR}` that isn't set stops Otari at start.
- Single settings also work as environment variables in `extraEnv`, as `OTARI_<SETTING>`, e.g. `OTARI_UPDATE_CHECK=false`.
- Providers can also be added at runtime on the dashboard's **Hosted providers** page; Otari stores their keys encrypted with `secret-key`.
- **Country file** for providers that serve only some countries: mount a folder with `extraVolumes`/`extraVolumeMounts` and set `OTARI_CLIENT_COUNTRY_DATABASE`, or upload the file on the dashboard's Settings page.
- `existingConfigMap` uses your own ConfigMap with a `config.yml` key instead.
- Set the database in `database`, not as `database_url` in `config`: the migration Job reads only `database`.

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
secrets:
  existingSecret: otari-keys
database:
  existingSecret: otari-db          # key database-url
redis:
  existingSecret: otari-redis       # key redis-url
files:
  backend: s3
  s3:
    bucket: otari-files
    region: eu-central-1
    existingSecret: otari-s3
persistence:
  enabled: false
publicBaseUrl: https://ai.example.com
forwardedAllowIps: "*"
networkPolicy:
  enabled: true
  from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
  hosts:
    - host: ai.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: otari-tls
      hosts: [ai.example.com]
# metrics.enabled exposes /metrics through the ingress too; turn it on once your proxy blocks the path.
config:
  default_pricing: true
extraEnvFrom:
  - secretRef:
      name: otari-provider-keys
```

## Upgrading

Every `helm upgrade` runs the migration Job first; if it fails, the pods are not changed. The old pods keep serving during the migration, so read Otari's [upgrade notes](https://github.com/mozilla-ai/otari/blob/main/docs/configuration.md#upgrading) before skipping many versions. Pin `image.tag`, or the chart version, to control when Otari updates.

## Known issues

- Otari's log lines are formatted for a terminal and wrapped at 80 columns, so one warning spans several lines in log collectors.
- Switching an existing release from `replicaCount` to `autoscaling.enabled` runs one pod for about 15 s, until the autoscaler restores `minReplicas`.
- `/metrics` can't be protected by Otari itself (see [Behind an ingress or Gateway](#behind-an-ingress-or-gateway)).

## FAQ

**Is there an official Otari Helm chart?** No. Mozilla.ai publishes the container image `mzdotai/otari`; this chart is maintained by upstreamyard and runs that image unchanged.

**How do I run Otari highly available on Kubernetes?** `replicaCount: 2` or more with PostgreSQL, `files.backend: s3` and Redis. See [Deployment modes](#deployment-modes).

**How do I monitor Otari with Prometheus?** `metrics.enabled=true` and `metrics.serviceMonitor.enabled=true`. Metrics include requests, upstream attempts per provider and model, tokens, cost, rate-limit hits and database pool usage.

**Where do I find the master key?** In the chart's Secret: `kubectl get secret otari -o jsonpath='{.data.master-key}' | base64 -d`. It signs you in to the dashboard and authorizes the management API.

**Why does a request fail with HTTP 424 `provider_not_configured`?** The model's provider isn't set up, or the model is switched off. Models of self-hosted providers such as llama.cpp arrive switched off and without a price: give them a price (0 is fine) and switch them on under **Hosted providers**.

**Why does Otari fail with `invalid literal for int() with base 10: 'tcp://…'`?** Kubernetes service links set `OTARI_PORT` for a Service named `otari`. This chart turns them off; in your own manifests set `enableServiceLinks: false`.

**Why do file uploads fail with `Read-only file system: '/app/otari-files'`?** Otari stores uploads under its working directory by default. This chart sets `OTARI_FILES_LOCAL_DIR=/data/files` or uses S3.

**Why did a pod crash with `duplicate key value violates unique constraint "pg_type_typname_nsp_index"`?** Several pods ran the database migrations at the same time, which happens with `migrations.enabled=false`. Keep the migration Job on.

**Why does Otari log `TooManyConnectionsError sqlstate=53300`?** PostgreSQL has no free connections. Each replica can use up to 35; see [Database connections](#database-connections).

**Can I use Argo CD or Flux?** Yes, with `secrets.existingSecret` (see [Keys and secrets](#keys-and-secrets)).

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Empty: spread replicas across nodes where possible. |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler on CPU. Needs PostgreSQL and `files.backend: s3`, like `replicaCount` > 1. |
| autoscaling.maxReplicas | int | `6` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `70` | Target average CPU utilisation in percent. |
| bootstrapApiKey | bool | `false` | Create a first API key on first start and print it to the log. Off by default, so no key lands in your log system; create keys with the master key instead. |
| config | object | `{}` | Otari configuration (`config.yml`) as YAML, e.g. `hosted_providers`, `default_pricing`, `budgets`. Mounted at `/etc/otari/config.yml`. Reference secrets as `${VAR}` and provide them with `extraEnv` or `extraEnvFrom`. Don't set `database_url` here; use `database`. |
| database.existingSecret | string | `""` | Existing Secret with the PostgreSQL URL. |
| database.existingSecretKey | string | `"database-url"` | Key of the URL in `existingSecret`. |
| database.url | string | `""` | PostgreSQL URL, e.g. `postgresql://otari:password@postgres.db.svc:5432/otari`. Empty: SQLite on the chart's volume (one replica, for evaluation). |
| existingConfigMap | string | `""` | Existing ConfigMap with a `config.yml` key, instead of `config`. |
| extraEnv | list | `[]` | Extra environment variables, e.g. provider keys referenced in `config` or any `OTARI_<SETTING>`. |
| extraEnvFrom | list | `[]` | Extra environment from ConfigMaps or Secrets, e.g. `[{secretRef: {name: otari-provider-keys}}]`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Otari container. |
| extraVolumes | list | `[]` | Extra volumes, e.g. a country file (`client_country_database`) or a CA bundle. |
| files.backend | string | `"local"` | Where uploaded files are stored: `local` (the chart's volume at `/data/files`) or `s3` (AWS S3 or any S3-compatible store). Several replicas need `s3`. |
| files.s3.accessKeyIdKey | string | `"access-key-id"` | Key of the access key ID in `existingSecret`. |
| files.s3.bucket | string | `""` | Bucket (required for `backend: s3`). It must exist. |
| files.s3.endpointUrl | string | `""` | Endpoint of an S3-compatible store, e.g. `http://seaweedfs.storage.svc:8333`. Empty: AWS S3. |
| files.s3.existingSecret | string | `""` | Existing Secret with the access key pair. Empty: the AWS default chain (e.g. IRSA via `serviceAccount.annotations`). Bedrock providers without their own credentials use the same pair. |
| files.s3.region | string | `""` | Region, e.g. `eu-central-1`. |
| files.s3.secretAccessKeyKey | string | `"secret-access-key"` | Key of the secret access key in `existingSecret`. |
| forwardedAllowIps | string | `""` | Proxy addresses or networks (comma-separated) whose `X-Forwarded-For` Otari trusts. Set it behind an ingress or Gateway, or every request seems to come from the proxy: all users then share one sign-in failure limit and one sign-up throttle, and logs show the proxy's address. `*` is safe only together with `networkPolicy` (see the README). |
| fullnameOverride | string | `""` | Override the full name of the release's resources. |
| httpRoute.annotations | object | `{}` | Route annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `[]` | Host names, e.g. `[otari.example.com]`. |
| httpRoute.parentRefs | list | `[]` | Gateways the route attaches to, e.g. `[{name: public, namespace: gateway}]`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"docker.io/mzdotai/otari"` | Otari image (the official image, published by Mozilla.ai for amd64 and arm64). |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion (the Otari version). |
| imagePullSecrets | list | `[]` | Pull secrets for private registries, e.g. `[{name: my-registry}]`. |
| ingress.annotations | object | `{}` | Ingress annotations. Streaming responses need a long read timeout, e.g. `nginx.ingress.kubernetes.io/proxy-read-timeout: "600"`. |
| ingress.className | string | `""` | Ingress class, e.g. `nginx`. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"otari.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Hosts and paths. |
| ingress.tls | list | `[]` | TLS settings, e.g. `[{secretName: otari-tls, hosts: [otari.example.com]}]`. |
| logLevel | string | `"INFO"` | Log level: DEBUG, INFO, WARNING, ERROR or CRITICAL. |
| metrics.enabled | bool | `false` | Serve Prometheus metrics at `/metrics` on the HTTP port. The endpoint has no authentication, so keep it off public ingresses (see the README). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a ServiceMonitor (Prometheus Operator). Needs `metrics.enabled`. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the `release` label your Prometheus selects. |
| migrations.activeDeadlineSeconds | int | `600` | Seconds before the migration Job is stopped. |
| migrations.backoffLimit | int | `1` | Retries of the migration Job. |
| migrations.enabled | bool | `true` | With PostgreSQL: run `otari migrate` in a Job before every install and upgrade, and start the pods with `OTARI_AUTO_MIGRATE=false`. If false, every pod migrates on start. With SQLite the pod always migrates on start. |
| migrations.resources | object | `{}` | Resources of the migration Job. Empty: `resources`. |
| nameOverride | string | `""` | Override the chart name. |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy that only lets `networkPolicy.from` reach Otari's port. Outgoing traffic (to providers) is not restricted. |
| networkPolicy.from | list | `[]` | Allowed sources (NetworkPolicy `from` entries), e.g. your ingress controller's namespace. Empty: any pod and address. Pods with the label `<full name>-client: "true"` are always allowed. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. Several replicas with `files.backend: local` need `[ReadWriteMany]`. |
| persistence.annotations | object | `{}` | PVC annotations. |
| persistence.enabled | bool | `true` | Volume at `/data` for the SQLite database and `local` file uploads. Only mounted when one of them is in use; otherwise `/data` is an emptyDir. The PVC is kept on `helm uninstall`. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"2Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class. Empty: the cluster default. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget (`maxUnavailable: 1`) when more than one replica runs. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as user `otari` (UID 1000). |
| preStopSleepSeconds | int | `10` | Seconds a stopping pod keeps serving before shutdown, so the Service and ingress stop sending it new requests first. |
| probes.livenessFailureThreshold | int | `6` | Liveness probe failures (every 10 s) before the pod is restarted. |
| probes.readinessFailureThreshold | int | `3` | Readiness probe failures (every 10 s) before the pod stops getting requests. Readiness includes the database. |
| probes.startupFailureThreshold | int | `60` | Startup probe failures (every 5 s) before the pod is restarted. Covers SQLite migrations on the first start. |
| publicBaseUrl | string | `""` | Address users reach Otari at, without a trailing slash, e.g. `https://ai.example.com`. Used in sign-in redirects and mail links. |
| redis.existingSecret | string | `""` | Existing Secret with the Redis URL. |
| redis.existingSecretKey | string | `"redis-url"` | Key of the URL in `existingSecret`. |
| redis.url | string | `""` | Redis URL for rate limits shared by all replicas, e.g. `redis://redis.cache.svc:6379/0`. Empty: every pod counts its own requests, so N replicas admit N times a limit. |
| replicaCount | int | `1` | Number of Otari pods. More than 1 needs `database.url` (PostgreSQL) and `files.backend: s3` (or a `ReadWriteMany` volume). Ignored when `autoscaling.enabled`. |
| resources | object | `{"limits":{"memory":"1536Mi"},"requests":{"cpu":"100m","memory":"768Mi"}}` | Resources. Otari uses about 550 MiB when idle. |
| secrets.existingSecret | string | `""` | Existing Secret with the keys `master-key`, `secret-key` and optionally `provider-account-pepper` and `provider-user-identifier-key`. Overrides the four values above. Use it with Argo CD and other tools that render with `helm template`. |
| secrets.masterKey | string | `""` | Master key for the management API and the first dashboard sign-in. Empty: generated on the first install and kept in the chart's Secret (key `master-key`). |
| secrets.providerAccountPepper | string | `""` | Key that names the provider account holding a copy of an attached file, at least 32 characters. Empty: generated and kept. |
| secrets.providerUserIdentifierKey | string | `""` | Key for the end-user identifier sent to providers, at least 32 characters. Empty: generated and kept. Changing it resets provider-side abuse history per user. |
| secrets.secretKey | string | `""` | Fernet key(s) that encrypt provider credentials stored in the database, comma-separated (the first encrypts). Empty: generated and kept. Back it up: without it, stored provider keys can't be decrypted. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `8000` | Service port (API, dashboard and `/metrics`). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | Annotations, e.g. a cloud IAM role for S3 or Bedrock. |
| serviceAccount.automountServiceAccountToken | bool | `false` | Mount the ServiceAccount token into the Otari pods. Otari itself doesn't need it. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | Name. Empty: the full name. |
| terminationGracePeriodSeconds | int | `120` | Seconds a stopping pod has to finish running requests. Otari waits for open streams, so a stream that takes longer is cut off. |
| tests.enabled | bool | `true` | Render the `helm test` pod (readiness, management API with the master key, and `/metrics` when on). |
| tolerations | list | `[]` | Tolerations. |
