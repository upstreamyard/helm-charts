# Docling Serve Helm chart: the Docling document conversion API on Kubernetes

![Version: 0.1.3](https://img.shields.io/badge/Version-0.1.3-informational?style=flat-square) ![AppVersion: 1.38.1](https://img.shields.io/badge/AppVersion-1.38.1-informational?style=flat-square)

Helm chart for **[Docling Serve](https://github.com/docling-project/docling-serve)**, the API server of [Docling](https://github.com/docling-project/docling). It converts PDF, DOCX, PPTX, XLSX, HTML and images into Markdown, JSON or HTML, with layout analysis, table structure and OCR, for RAG and document AI pipelines. It runs a **single API server**, or **scalable API servers plus RQ workers** with a job queue in Redis, and **KEDA autoscaling on the queue length** down to zero workers. An **API key is required by default** (generated), and the pods run non-root with a read-only root filesystem. It works with Docling Serve's official **CPU and CUDA images**, and includes Prometheus metrics, a ServiceMonitor and a `helm test` that converts a real PDF.

> Community chart by **upstreamyard**, not an official Docling chart. Docling Serve is © its authors, licensed under MIT. The chart uses the official Docling Serve images unchanged.

**AI agents and coding assistants:** this README is the complete reference for the chart. Every value is listed under [Values](#values), and `values.schema.json` validates them.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install docling upstreamyard/docling-serve
```

Or from the OCI registry:

```bash
helm install docling oci://ghcr.io/upstreamyard/charts/docling-serve
```

The install notes show the in-cluster URL and the command that prints the generated API key. Then check that a document converts:

```bash
helm test docling
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install docling upstreamyard/docling-serve --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## What the chart does

- **API server** (`docling-serve run`) on port 5001, with the models for layout, tables, picture classification, RapidOCR and EasyOCR already in the image. The pod is ready about 10 seconds after it starts.
- **API key:** `DOCLING_SERVE_API_KEY` from a Secret, generated on install and kept across upgrades, or from your own Secret. Clients send it in the `X-Api-Key` header; requests without it get `401`.
- **Probes:** `/livez` for startup and liveness, `/readyz` for readiness (`503` until the models are loaded and, with RQ, Redis answers).
- **RQ workers** (`docling-serve rq-worker`) in their own Deployment with `engine.kind: rq`, optionally scaled by KEDA on the Redis queue, and optionally on GPU nodes with a CUDA image.
- **Extra models:** `models.download` fetches more models (e.g. for formula enrichment) in an init container.
- **Security:** non-root (UID 1001), read-only root filesystem with `/tmp` as an emptyDir, all capabilities dropped, no ServiceAccount token.
- **Validation:** the install fails with a clear message on combinations that don't work, e.g. several API pods with the local engine.

## Deployment modes

### Single API server (default)

The API pod converts documents itself (the **local engine**), `engine.local.numWorkers` at a time (default 2).

```yaml
engine:
  local:
    numWorkers: 2
resources:
  requests:
    cpu: "2"
    memory: 2Gi
  limits:
    memory: 6Gi
```

- **Tested in kind** (CPU image, 16-core host): the 9-page DocLayNet paper (arXiv 2206.01062, with tables and figures) converted in 13 seconds, with a peak memory of 2.5 GB.
- Only **one API pod** works with the local engine. Async tasks live in the pod's memory, so a status request that reaches another pod gets `Task not found` (tested). The chart refuses `replicaCount > 1` and `autoscaling.enabled` here.

### Scalable: API servers plus RQ workers (Redis)

The API pods only queue jobs in Redis and return results, and the worker pods convert. API pods and workers scale independently. Bring your own Redis; the chart doesn't install one.

```yaml
engine:
  kind: rq
  rq:
    existingSecret: docling-redis      # key: redis-url, e.g. redis://:password@redis.example.svc:6379/0
replicaCount: 2
resources:
  requests:
    cpu: 250m
    memory: 1Gi
worker:
  replicaCount: 4
```

- **Tested in kind:** a task submitted to one API pod was polled and fetched from the other. A rolling upgrade from 1.36.0 to 1.37.0 replaced API and worker pods in 12 seconds.
- **Graceful shutdown:** a worker that gets `SIGTERM` finishes the document it is converting, then exits (tested). `worker.terminationGracePeriodSeconds` (300) is the limit; a conversion that runs longer is cut off and the task is reported as `failure` about 90 seconds later. It is not retried, so clients should resubmit failed tasks.
- Each worker converts one document at a time. Several installations on one Redis need different `engine.rq.queueName` values or Redis databases.

### Autoscaling workers with KEDA

With [KEDA](https://keda.sh) in the cluster, a ScaledObject scales the workers on the length of the RQ queue (`rq:queue:<queueName>` in Redis):

```yaml
engine:
  kind: rq
  rq:
    existingSecret: docling-redis
worker:
  autoscaling:
    enabled: true
    minReplicaCount: 0                 # no workers while the queue is empty
    maxReplicaCount: 10
    listLength: 2                      # waiting jobs per worker
    redisAddress: redis.example.svc:6379
    redisDatabase: 0
    redisPasswordSecret: docling-redis # key: redis-password; leave empty without a password
```

- **Tested in kind with KEDA 2.21:** 8 queued jobs scaled the workers from 1 to 4 within 20 seconds, and all jobs succeeded, also with a password-protected Redis. From zero workers, a new job was picked up after about 10 seconds.
- KEDA reads Redis directly, so it needs the address, database and password separately from `engine.rq`.
- API pods scale with a regular HorizontalPodAutoscaler on CPU: `autoscaling.enabled: true` (RQ only).

### GPU workers

Use a CUDA image for the workers and request a GPU. API pods in RQ mode don't convert, so they can stay on the CPU image:

```yaml
engine:
  kind: rq
worker:
  image:
    repository: ghcr.io/docling-project/docling-serve-cu128
  resources:
    limits:
      nvidia.com/gpu: 1
      memory: 8Gi
  nodeSelector:
    nvidia.com/gpu.present: "true"
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
```

The GPU images were not tested by us (no GPU in our test cluster). With the local engine, set `image.repository` and the GPU resources on the API pod instead.

## Connecting clients

- **In-cluster URL:** `http://<release>-docling-serve.<namespace>.svc:5001`, with the header `X-Api-Key: <key>`.
- **Convert a URL** (synchronous, waits up to 120 seconds by default):

  ```bash
  curl -X POST http://<release>-docling-serve:5001/v1/convert/source \
    -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" \
    -d '{"sources": [{"kind": "http", "url": "https://arxiv.org/pdf/2206.01062"}]}'
  ```

- **Upload a file:** `{"sources": [{"kind": "file", "filename": "doc.pdf", "base64_string": "<base64>"}]}` to the same endpoint, or a multipart upload to `/v1/convert/file`.
- **Long documents:** use `/v1/convert/source/async`, then poll `/v1/status/poll/<task_id>` and fetch `/v1/result/<task_id>`.
- The API reference is at `/docs`, and `ui.enabled: true` serves a web UI at `/ui`. See [Docling Serve's usage guide](https://github.com/docling-project/docling-serve/blob/main/docs/usage.md) for all options, and use `sources` as shown above: in 1.37.0 the `file_sources` field from older examples is rejected with `422`.

## Choosing the image

All images are published by the Docling project for every release, tagged `v<version>`. The chart sets the tag from its appVersion; pick the variant with `image.repository` (and `worker.image.repository` for RQ workers):

| `image.repository` | Use | Platforms | Tested by us |
|---|---|---|---|
| `ghcr.io/docling-project/docling-serve-cpu` (default) | CPU-only nodes, about 2.2 GB compressed | amd64, arm64 | yes (amd64) |
| `ghcr.io/docling-project/docling-serve-cu128` | NVIDIA GPU, CUDA 12.8 | amd64, arm64 | no |
| `ghcr.io/docling-project/docling-serve-cu130` | NVIDIA GPU, CUDA 13.0 | amd64, arm64 | no |
| `ghcr.io/docling-project/docling-serve` | PyPI build; on amd64 it includes CUDA libraries and is about twice the size | amd64, arm64 | no |

The same images are on `quay.io/docling-project/...`.

## Extra models

The image contains the models for the default pipeline. Features such as formula and code enrichment or picture descriptions need more models, and Docling Serve doesn't download them at runtime. Without them the task fails with `Model '...' not found in artifacts_path` in the logs, and the API answers `404 Task result not found` (tested with formula enrichment). List the models in `models.download`:

```yaml
models:
  download: [granitedocling, smolvlm]    # formula/code enrichment, picture descriptions
  existingClaim: docling-models          # optional; ReadWriteMany for several pods
```

- An init container copies the image's models to `/models`, downloads the extra ones from Hugging Face and the pods use `/models` (`DOCLING_SERVE_ARTIFACTS_PATH`).
- Without `existingClaim` every pod downloads at start (`granitedocling` added about 500 MB and 10 seconds in our test). With a PersistentVolumeClaim the download happens once.
- **Tested:** `granitedocling` made formula enrichment work, and `smolvlm` picture descriptions (which end with a stray `<end_of_utterance>` token in 1.37.0). The names are those of `docling-tools models download`, e.g. `granitedocling`, `smolvlm`, `granite_vision`, `code_formula`, `tableformerv2`.

## Configuration

Docling Serve is configured with environment variables. Put them in `extraEnv` (or `extraEnvFrom` for secrets); they apply to API and worker pods:

```yaml
extraEnv:
  - name: DOCLING_SERVE_MAX_NUM_PAGES
    value: "500"
  - name: DOCLING_SERVE_LOG_FORMAT
    value: json
  - name: DOCLING_SERVE_ENABLE_REMOTE_SERVICES   # e.g. picture descriptions through an OpenAI-compatible API
    value: "true"
```

The full list is in [Docling Serve's configuration reference](https://github.com/docling-project/docling-serve/blob/main/docs/configuration.md). The chart sets `DOCLING_SERVE_API_KEY`, `DOCLING_SERVE_ENG_*`, `DOCLING_SERVE_ENABLE_UI` and `DOCLING_SERVE_ARTIFACTS_PATH` itself. For a YAML config file (`DOCLING_SERVE_CONFIG_FILE`), mount a ConfigMap with `extraVolumes` and `extraVolumeMounts`.

## Production example

```yaml
# values-prod.yaml
engine:
  kind: rq
  rq:
    existingSecret: docling-redis       # key: redis-url
apiKey:
  existingSecret: docling-api-key       # key: api-key
replicaCount: 2
resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    memory: 2Gi
worker:
  autoscaling:
    enabled: true
    minReplicaCount: 1
    maxReplicaCount: 8
    redisAddress: redis.example.svc:6379
    redisPasswordSecret: docling-redis  # key: redis-password
  resources:
    requests:
      cpu: "2"
      memory: 3Gi
    limits:
      memory: 6Gi
extraEnv:
  - name: DOCLING_SERVE_MAX_NUM_PAGES
    value: "500"
  - name: DOCLING_SERVE_LOG_FORMAT
    value: json
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 100m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
  hosts:
    - host: docling.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: docling-tls
      hosts: [docling.example.com]
metrics:
  serviceMonitor:
    enabled: true
```

## FAQ

**Is there an official Docling Serve Helm chart?** The Docling project publishes the container images but no Helm chart, and Artifact Hub had none before this one. This chart is maintained by upstreamyard and uses the official images unchanged.

**How do I run Docling Serve highly available and scaled on Kubernetes?** Use `engine.kind: rq` with Redis, 2 or more API pods, and workers scaled by KEDA. See [Deployment modes](#deployment-modes).

**Why can't I run several API pods with the default engine?** The local engine keeps tasks in the memory of the pod that received them. Async requests to another pod fail with `Task not found`. Switch to `engine.kind: rq`.

**How do I monitor it with Prometheus?** `/metrics` on the API port has HTTP, conversion and (with RQ) queue metrics; `metrics.serviceMonitor.enabled: true` adds a ServiceMonitor. Workers export metrics only via OTLP (`DOCLING_SERVE_OTEL_ENABLE_OTLP_METRICS`, `OTEL_EXPORTER_OTLP_ENDPOINT`).

**Which endpoints work without the API key?** `/health`, `/livez`, `/readyz`, `/metrics`, `/version`, `/v1/capabilities` and the API docs (`/docs`, `/openapi.json`). Turn off the docs with `DOCLING_SERVE_ENABLE_API_DOCS=false` and the version with `DOCLING_SERVE_SHOW_VERSION_INFO=false` if they must not be public.

**Why does a conversion fail with "Model not found in artifacts_path"?** The option needs a model that isn't in the image. Add it to `models.download` (see [Extra models](#extra-models)).

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity for the API pods. |
| apiKey.enabled | bool | `true` | Require an API key (`DOCLING_SERVE_API_KEY`). Without it, anyone who reaches the service can convert documents and make the server fetch any URL. |
| apiKey.existingSecret | string | `""` | Name of an existing Secret that holds the API key. |
| apiKey.existingSecretKey | string | `"api-key"` | Key in `existingSecret` that holds the API key. |
| apiKey.value | string | `""` | The API key. If empty and no `existingSecret` is set, the chart generates one and keeps it across upgrades. |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler for the API pods. Requires `engine.kind: rq`. |
| autoscaling.maxReplicas | int | `5` | Maximum API pods. |
| autoscaling.minReplicas | int | `2` | Minimum API pods. |
| autoscaling.targetCPUUtilizationPercentage | int | `80` | Target CPU utilisation in percent. |
| engine.kind | string | `"local"` | Compute engine for conversions: `local` (in the API pod) or `rq` (separate worker pods with a job queue in Redis; required for more than 1 API pod). |
| engine.local.numWorkers | int | `2` | Conversions that run at the same time in each API pod (`DOCLING_SERVE_ENG_LOC_NUM_WORKERS`). |
| engine.rq.existingSecret | string | `""` | Name of an existing Secret that holds the Redis URL. |
| engine.rq.existingSecretKey | string | `"redis-url"` | Key in `existingSecret` that holds the Redis URL. |
| engine.rq.queueName | string | `"convert"` | RQ queue name (`DOCLING_SERVE_ENG_RQ_QUEUE_NAME`). Change it when several installations share one Redis. |
| engine.rq.redisUrl | string | `""` | Redis URL for the `rq` engine, e.g. `redis://:password@redis:6379/0`. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| extraEnv | list | `[]` | Settings as environment variables, e.g. `DOCLING_SERVE_MAX_NUM_PAGES`, `DOCLING_SERVE_LOG_FORMAT`, `DOCLING_SERVE_ENABLE_REMOTE_SERVICES`. Applies to API and worker pods. See https://github.com/docling-project/docling-serve/blob/main/docs/configuration.md |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps, e.g. S3 credentials for artifact storage. Applies to API and worker pods. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the docling-serve containers. |
| extraVolumes | list | `[]` | Extra volumes for API and worker pods, e.g. a ConfigMap with a config file for `DOCLING_SERVE_CONFIG_FILE`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/docling-project/docling-serve-cpu"` | Image repository. One of Docling Serve's official images: `ghcr.io/docling-project/docling-serve-cpu` (CPU), `-cu128` or `-cu130` (NVIDIA GPU), or `ghcr.io/docling-project/docling-serve` (PyPI build). See "Choosing the image". |
| image.tag | string | `""` | Image tag. Defaults to `v` + the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. Large uploads may need e.g. `nginx.ingress.kubernetes.io/proxy-body-size` and longer read timeouts for synchronous conversions. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"docling.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/livez","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on `/livez`. It fails when the task queue processor has died. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor for `/metrics` on the API pods (request, conversion and RQ queue metrics). |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the label your Prometheus selects on. |
| models.download | list | `[]` | Extra models to download before the pods start, e.g. `[granitedocling, smolvlm]` for formula/code enrichment and picture descriptions. The names are the arguments of `docling-tools models download`. Empty: use the models in the image. |
| models.existingClaim | string | `""` | Existing PersistentVolumeClaim for the models (ReadWriteMany for several pods). Downloads happen once and survive restarts. Empty: an emptyDir per pod, downloaded at every pod start. |
| models.resources | object | `{}` | Resources for the model download init container. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector for the API pods. |
| pdb.enabled | bool | `true` | Create a PodDisruptionBudget for the API pods (only with more than 1 replica or autoscaling). |
| pdb.maxUnavailable | int | `1` | Maximum API pods that may be unavailable during voluntary disruptions. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":1001,"runAsGroup":1001,"runAsNonRoot":true,"runAsUser":1001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as non-root UID 1001. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/readyz","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Readiness probe on `/readyz`: 503 until the models are loaded and, with `rq`, Redis answers. |
| replicaCount | int | `1` | Number of API pods. More than 1 requires `engine.kind: rq`: the local engine keeps tasks in the pod's memory, so a status request that reaches another pod fails. |
| resources | object | `{"limits":{"memory":"6Gi"},"requests":{"cpu":"1","memory":"2Gi"}}` | Resources for an API pod. With the local engine it converts documents itself; with `rq` it needs much less. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The root filesystem is read-only; `/tmp` is an emptyDir. |
| service.port | int | `5001` | Service port. Docling Serve listens on 5001 inside the container. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations, e.g. for cloud IAM roles used by S3 artifact storage. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Docling Serve does not use the Kubernetes API with the local and rq engines. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/livez","port":"http"},"periodSeconds":5}` | Startup probe. `/livez` answers as soon as the server runs; models load in the background. |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after SIGTERM for an API pod. |
| tmpSizeLimit | string | `"10Gi"` | Size limit of the `/tmp` emptyDir (uploads, results and caches). |
| tolerations | list | `[]` | Tolerations for the API pods. |
| ui | object | `{"enabled":false}` | Serve the web UI at `/ui` (`DOCLING_SERVE_ENABLE_UI`). It uses the same API key. |
| worker.affinity | object | `{}` | Affinity for the workers. |
| worker.autoscaling.cooldownPeriod | int | `300` | Seconds without jobs before KEDA scales down. |
| worker.autoscaling.enabled | bool | `false` | Scale workers on the Redis queue length with a KEDA ScaledObject. Needs KEDA installed in the cluster. |
| worker.autoscaling.listLength | int | `2` | Waiting jobs per worker that trigger a scale-up. |
| worker.autoscaling.maxReplicaCount | int | `10` | Maximum workers. |
| worker.autoscaling.minReplicaCount | int | `1` | Minimum workers. 0 stops all workers while the queue is empty. |
| worker.autoscaling.pollingInterval | int | `15` | Seconds between queue checks. |
| worker.autoscaling.redisAddress | string | `""` | Redis host:port for KEDA, e.g. `redis.example.svc:6379`. KEDA can't read the Redis URL, so set it here. |
| worker.autoscaling.redisDatabase | int | `0` | Redis database number, as in the Redis URL (`redis://host:6379/<n>`). |
| worker.autoscaling.redisPasswordSecret | string | `""` | Name of a Secret with the Redis password for KEDA (empty: no password). |
| worker.autoscaling.redisPasswordSecretKey | string | `"redis-password"` | Key in `redisPasswordSecret` that holds the password. |
| worker.autoscaling.redisTLS | bool | `false` | Connect to Redis over TLS. |
| worker.extraEnv | list | `[]` | Extra environment variables for the workers only. |
| worker.image.repository | string | `""` | Worker image repository, e.g. a CUDA image for GPU workers. Defaults to `image.repository`. |
| worker.image.tag | string | `""` | Worker image tag. Defaults to `image.tag`. |
| worker.nodeSelector | object | `{}` | Node selector for the workers, e.g. GPU nodes. |
| worker.podAnnotations | object | `{}` | Extra worker pod annotations. |
| worker.replicaCount | int | `2` | Number of worker pods. Each converts one document at a time. Ignored when `worker.autoscaling.enabled`. |
| worker.resources | object | `{"limits":{"memory":"6Gi"},"requests":{"cpu":"1","memory":"2Gi"}}` | Resources for a worker. For GPU workers add e.g. `nvidia.com/gpu: 1` to limits. |
| worker.terminationGracePeriodSeconds | int | `300` | Seconds Kubernetes waits after SIGTERM. A worker finishes the document it is converting before it exits; if that takes longer, the conversion fails. |
| worker.tolerations | list | `[]` | Tolerations for the workers. |
