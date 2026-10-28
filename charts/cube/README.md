# Cube Helm chart

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square) ![AppVersion: 1.8.14](https://img.shields.io/badge/AppVersion-1.8.14-informational?style=flat-square)

Helm chart for [Cube](https://github.com/cube-js/cube), the open-source semantic layer and data API for BI and AI. It runs Cube's production setup on Kubernetes with Cube's official images [`cubejs/cube`](https://hub.docker.com/r/cubejs/cube) and [`cubejs/cubestore`](https://hub.docker.com/r/cubejs/cubestore): API pods, a refresh worker, and a Cube Store cluster (router and workers) for pre-aggregations.

> Community chart by **upstreamyard**, not an official Cube chart. Cube is © its authors, licensed under Apache-2.0 and MIT.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install cube upstreamyard/cube -f values.yaml
```

A minimal `values.yaml` with PostgreSQL as the data source and S3 for Cube Store:

```yaml
apiSecret:
  existingSecret: cube-api          # key: api-secret, e.g. from `openssl rand -hex 32`
datasource:
  type: postgres
  host: warehouse.example.internal
  name: analytics
  user: cube
  existingSecret: cube-db           # key: password
model:
  existingConfigMap: cube-model     # your model files, e.g. kubectl create configmap cube-model --from-file=model/
cubestore:
  storage:
    type: s3
    s3:
      bucket: my-cube-store
      region: eu-central-1
  extraEnvFrom:
    - secretRef:
        name: cube-store-s3         # CUBESTORE_AWS_ACCESS_KEY_ID, CUBESTORE_AWS_SECRET_ACCESS_KEY
```

Or from the OCI registry: `helm install cube oci://ghcr.io/upstreamyard/charts/cube -f values.yaml`.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install cube upstreamyard/cube --verify --keyring upstreamyard.gpg -f values.yaml
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **A data source** that Cube supports (PostgreSQL, Snowflake, BigQuery, ClickHouse, …). This chart does not deploy one.
- **Shared storage for Cube Store:** an S3 or GCS bucket, or any S3-compatible store (`minio`). The router and all workers read and write it. A shared volume (`sharedVolume`) also works, but Cube doesn't recommend it for production, and it must be `ReadWriteMany` when Cube Store pods run on several nodes.
- **An API secret**, which signs the tokens your apps send.
- **Your data model** (YAML or JS files).

## What the chart does

- **API** (`<release>-cube-api`): any number of pods behind the Service on port 4000 (REST, GraphQL and SQL-over-HTTP APIs).
- **Refresh worker** (`<release>-cube-refresh-worker`): one pod that builds and refreshes pre-aggregations in Cube Store, as in Cube's production setup.
- **Cube Store**: a router StatefulSet and a worker StatefulSet. Workers get stable names through a headless Service, and the chart wires `CUBESTORE_WORKERS`, `CUBESTORE_SERVER_NAME` and `CUBESTORE_META_ADDR` for you. Change `cubestore.workers` to scale. The router writes a snapshot of its metadata to the shared storage every 5 minutes and restores it after a restart.
- **Data model**: copied into `/cube/conf/model` of the API and refresh worker when a pod starts, from `model.files` or your own ConfigMap. (Mounting a ConfigMap folder directly doesn't work: Kubernetes adds hidden links to it, and Cube reads every model file twice.) Pods restart when `model.files` changes; after changing your own ConfigMap, run `kubectl rollout restart` for the API and refresh worker.
- **Probes:** the API is ready when `/readyz` passes (it tests the data source and Cube Store); liveness only checks that the port is open, so a data source outage doesn't restart pods. The Cube Store router uses its `/livez` and `/readyz` endpoints on port 3031; workers have none, so a TCP check is used.
- **Security:** all pods run as non-root UID 10001 (the images default to root), drop all capabilities, and don't mount a ServiceAccount token. Cube Store keeps its local data in an `emptyDir` at `/cube/data`.

**Authentication:** every API request needs a JWT signed with the API secret (HS256) in the `Authorization` header; requests without a valid token get `403`. For tokens from your identity provider, set `CUBEJS_JWK_URL` and the related variables through `extraEnv`. See Cube's [authentication guide](https://docs.cube.dev/api-reference/authentication).

## Configuration

**Other data sources:** set `datasource.type` and pass the driver's variables through `extraEnv` / `extraEnvFrom`, e.g. for BigQuery:

```yaml
datasource:
  type: bigquery
extraEnv:
  - name: CUBEJS_DB_BQ_PROJECT_ID
    value: my-project
extraEnvFrom:
  - secretRef:
      name: cube-bigquery           # CUBEJS_DB_BQ_CREDENTIALS
```

All variables are listed in Cube's [environment variable reference](https://docs.cube.dev/reference/configuration/environment-variables).

**`cube.js` configuration file:** mount it next to the model:

```yaml
extraVolumes:
  - name: cube-config
    configMap:
      name: cube-config             # key: cube.js
extraVolumeMounts:
  - name: cube-config
    mountPath: /cube/conf/cube.js
    subPath: cube.js
```

**Cube Store storage credentials** go into a Secret referenced by `cubestore.extraEnvFrom`:

| Storage | Variables |
|---|---|
| `s3` | `CUBESTORE_AWS_ACCESS_KEY_ID`, `CUBESTORE_AWS_SECRET_ACCESS_KEY` (or workload identity through `serviceAccount.annotations`) |
| `gcs` | `CUBESTORE_GCP_CREDENTIALS` (base64-encoded service account key) |
| `minio` | `CUBESTORE_MINIO_ACCESS_KEY_ID`, `CUBESTORE_MINIO_SECRET_ACCESS_KEY` |

**arm64 nodes:** Cube Store has no multi-arch images. Set `cubestore.image.variant: arm64v8` on arm64 nodes, or `non-avx` on amd64 CPUs without AVX. The `cubejs/cube` image is multi-arch.

**An existing Cube Store:** set `cubestore.enabled: false` and `cubestore.external.host`.

## Known issues

- **S3-compatible storage needs a sub-path.** With `cubestore.storage.type: minio` and no `subPath`, Cube Store 1.8 can't find its own uploads ("can't be listed after upload"), so pre-aggregations never build. The chart therefore sets `subPath: cubestore` and rejects an empty value. Tested with RustFS; MinIO itself no longer publishes images.
- **Router restart in the first minutes.** Until the router has written its first metadata snapshot (5 minutes after a new installation), a router restart starts with empty metadata, and the refresh worker rebuilds all pre-aggregations.
- **`helm test`** calls `/cubejs-api/v1/meta`; it fails if your `cube.js` sets a different `basePath`.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity for all pods. |
| api.livenessProbe | object | `{"periodSeconds":10,"tcpSocket":{"port":"http"}}` | Liveness probe: the API port accepts connections. Not `/livez`, which fails while the data source is down and would restart healthy pods. |
| api.podAnnotations | object | `{}` | Extra pod annotations. |
| api.readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/readyz","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Readiness probe on `/readyz`, which tests the data source and Cube Store. |
| api.replicaCount | int | `1` | Number of API pods. |
| api.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"250m","memory":"512Mi"}}` | Resources for the API. |
| api.startupProbe | object | `{"failureThreshold":60,"periodSeconds":2,"tcpSocket":{"port":"http"}}` | Startup probe: the API port accepts connections. |
| apiSecret.existingSecret | string | `""` | Name of an existing Secret that holds the API secret (recommended for production). |
| apiSecret.existingSecretKey | string | `"api-secret"` | Key in `existingSecret` that holds the API secret. |
| apiSecret.value | string | `""` | The secret (`CUBEJS_API_SECRET`), e.g. from `openssl rand -hex 32`. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| cubestore.enabled | bool | `true` | Deploy Cube Store (a router and workers). If false, set `cubestore.external.host` to an existing Cube Store. |
| cubestore.external.host | string | `""` | Host of an existing Cube Store router, when `cubestore.enabled` is false (`CUBEJS_CUBESTORE_HOST`). |
| cubestore.external.port | int | `3030` | HTTP port of the existing Cube Store router (`CUBEJS_CUBESTORE_PORT`). |
| cubestore.extraEnv | list | `[]` | Extra environment variables for all Cube Store pods, e.g. `CUBESTORE_LOG_LEVEL`. |
| cubestore.extraEnvFrom | list | `[]` | Extra environment variables from Secrets for all Cube Store pods, e.g. storage credentials (`CUBESTORE_AWS_ACCESS_KEY_ID`, `CUBESTORE_AWS_SECRET_ACCESS_KEY`, `CUBESTORE_MINIO_ACCESS_KEY_ID`, `CUBESTORE_MINIO_SECRET_ACCESS_KEY`, `CUBESTORE_GCP_CREDENTIALS`). |
| cubestore.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| cubestore.image.repository | string | `"cubejs/cubestore"` | Cube Store image repository. |
| cubestore.image.tag | string | `""` | Cube Store image tag. Defaults to `v` + the chart's appVersion, plus `-<variant>`. |
| cubestore.image.variant | string | `""` | Image variant. Cube Store has no multi-arch images: use `arm64v8` on arm64 nodes and `non-avx` on CPUs without AVX. Empty means amd64. |
| cubestore.router.resources | object | `{"limits":{"memory":"2Gi"},"requests":{"cpu":"250m","memory":"512Mi"}}` | Resources for the Cube Store router. |
| cubestore.storage.gcs.bucket | string | `""` | GCS bucket (`CUBESTORE_GCS_BUCKET`). |
| cubestore.storage.gcs.subPath | string | `""` | Path prefix in the bucket (`CUBESTORE_GCS_SUB_PATH`). |
| cubestore.storage.minio.bucket | string | `""` | Bucket (`CUBESTORE_MINIO_BUCKET`). |
| cubestore.storage.minio.endpoint | string | `""` | Endpoint of the S3-compatible server (`CUBESTORE_MINIO_SERVER_ENDPOINT`), e.g. `http://minio:9000`. |
| cubestore.storage.minio.region | string | `""` | Region (`CUBESTORE_MINIO_REGION`). |
| cubestore.storage.minio.subPath | string | `"cubestore"` | Path prefix in the bucket (`CUBESTORE_MINIO_SUB_PATH`). Must not be empty: without it, Cube Store 1.8 can't find its own uploads on S3-compatible servers ("can't be listed after upload"). |
| cubestore.storage.s3.bucket | string | `""` | S3 bucket (`CUBESTORE_S3_BUCKET`). |
| cubestore.storage.s3.region | string | `""` | S3 region (`CUBESTORE_S3_REGION`). |
| cubestore.storage.s3.subPath | string | `""` | Path prefix in the bucket (`CUBESTORE_S3_SUB_PATH`). |
| cubestore.storage.sharedVolume.accessModes | list | `["ReadWriteMany"]` | Access modes of the created claim. |
| cubestore.storage.sharedVolume.create | bool | `false` | Create the claim instead (for tests and small single-node setups). |
| cubestore.storage.sharedVolume.existingClaim | string | `""` | Existing PersistentVolumeClaim mounted by the router and all workers (`CUBESTORE_REMOTE_DIR`). Must be `ReadWriteMany` when Cube Store pods run on several nodes. Cube doesn't recommend this for production. |
| cubestore.storage.sharedVolume.size | string | `"10Gi"` | Size of the created claim. |
| cubestore.storage.sharedVolume.storageClass | string | `""` | Storage class of the created claim. Empty uses the cluster default. |
| cubestore.storage.type | string | `""` | `s3`, `gcs`, `minio` (any S3-compatible store) or `sharedVolume`. Cube recommends S3 or GCS for production; credentials go into `cubestore.extraEnvFrom` (see README). |
| cubestore.terminationGracePeriodSeconds | int | `10` | Seconds Kubernetes waits after SIGTERM. Cube Store doesn't handle SIGTERM, so a long grace period only slows down rollouts. |
| cubestore.worker.resources | object | `{"limits":{"memory":"4Gi"},"requests":{"cpu":"500m","memory":"1Gi"}}` | Resources for each Cube Store worker. |
| cubestore.workers | int | `2` | Number of Cube Store workers. |
| datasource.existingSecret | string | `""` | Name of an existing Secret that holds the password. |
| datasource.existingSecretPasswordKey | string | `"password"` | Key in `existingSecret` that holds the password. |
| datasource.host | string | `""` | Database host (`CUBEJS_DB_HOST`). |
| datasource.name | string | `""` | Database name (`CUBEJS_DB_NAME`). |
| datasource.password | string | `""` | Database password (`CUBEJS_DB_PASS`). Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| datasource.port | string | `""` | Database port (`CUBEJS_DB_PORT`). Empty uses the driver's default. |
| datasource.type | string | `""` | Database type (`CUBEJS_DB_TYPE`), e.g. `postgres`, `mysql`, `clickhouse`, `snowflake`, `bigquery`. See https://docs.cube.dev/admin/connect-to-data/data-sources |
| datasource.user | string | `""` | Database user (`CUBEJS_DB_USER`). |
| extraEnv | list | `[]` | Extra environment variables for the API and refresh worker, e.g. `CUBEJS_DB_SSL`, JWT settings (`CUBEJS_JWK_URL`, …) or driver settings. See https://docs.cube.dev/reference/configuration/environment-variables |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps for the API and refresh worker. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the API and refresh worker, e.g. `cube.js` at `/cube/conf/cube.js` (with `subPath`). |
| extraVolumes | list | `[]` | Extra volumes for the API and refresh worker pods, e.g. a ConfigMap with `cube.js`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"cubejs/cube"` | Image repository for the Cube API and refresh worker. |
| image.tag | string | `""` | Image tag. Defaults to `v` + the chart's appVersion (Cube's tags start with `v`). |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the Cube API. |
| ingress.hosts | list | `[{"host":"cube.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| model.existingConfigMap | string | `""` | Name of an existing ConfigMap with your model files (each key becomes a file). |
| model.files | object | `{}` | Model files as `filename: content`. The chart stores them in a ConfigMap. Ignored when `existingConfigMap` is set. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector for all pods. |
| podLabels | object | `{}` | Extra labels for all pods. |
| podSecurityContext | object | `{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context for all pods. The images default to root; the chart runs them as UID 10001. |
| refreshWorker.enabled | bool | `true` | Run a refresh worker, which builds and refreshes pre-aggregations in Cube Store. Cube's production setup has exactly one. |
| refreshWorker.podAnnotations | object | `{}` | Extra pod annotations. |
| refreshWorker.resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"250m","memory":"512Mi"}}` | Resources for the refresh worker. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Container security context for all containers. |
| service.port | int | `4000` | Port of the Cube API (REST, GraphQL and SQL-over-HTTP APIs). |
| service.type | string | `"ClusterIP"` | Service type of the Cube API. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations, e.g. for cloud workload identity to reach S3 or GCS. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Cube does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount (used by all Cube pods). |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after SIGTERM for the API and refresh worker. They stop within a second. |
| tolerations | list | `[]` | Tolerations for all pods. |
