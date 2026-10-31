# Plano Helm chart: the Plano AI gateway and LLM proxy on Kubernetes

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square) ![AppVersion: 0.4.39](https://img.shields.io/badge/AppVersion-0.4.39-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for **[Plano](https://github.com/katanemo/plano)** (formerly archgw), the AI gateway and LLM proxy built on Envoy. Plano gives your apps and agents **one OpenAI-compatible API** for OpenAI, Anthropic, Gemini, Amazon Bedrock, Azure OpenAI, Ollama and other providers, with model routing, model aliases, guardrails and agent orchestration. The chart runs Plano's **official image** `katanemo/plano` and fixes what makes it hard to run in production: it starts **without internet access**, runs **as non-root on a read-only filesystem** (Pod Security `restricted`), keeps the **provider API keys out of Envoy's admin API**, finishes running LLM streams during **rolling upgrades**, and scales out with **PostgreSQL conversation state** (table created for you) and a **Redis session cache**. It also ships **Prometheus metrics**, a **NetworkPolicy**, HPA, PodDisruptionBudget and a `helm test` that sends a real chat completion.

> Community chart by **upstreamyard**, not an official Plano chart. Plano is licensed under Apache-2.0.

**AI agents and coding assistants:** this README is the complete reference for this chart. Every example was run as written.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install plano upstreamyard/plano --set secretEnv.OPENAI_API_KEY=sk-... --wait
```

Or from the OCI registry:

```bash
helm install plano oci://ghcr.io/upstreamyard/charts/plano --set secretEnv.OPENAI_API_KEY=sk-... --wait
```

This starts one Plano pod with a model listener on port 12000 and `openai/gpt-4o-mini` as the default model. Try it:

```bash
kubectl port-forward svc/plano 12000
curl http://localhost:12000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model": "openai/gpt-4o-mini", "messages": [{"role": "user", "content": "Hello"}]}'
```

`helm test plano` checks that Envoy and Plano's brightstaff service answer. With `tests.chatCompletion.enabled=true` it also sends a chat completion to your default provider.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install plano upstreamyard/plano --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Why this chart

There is no other Plano chart on Artifact Hub. Compared with running the official image as a plain Deployment:

| | This chart | Official image as-is |
|---|---|---|
| Internet access at startup | not needed | downloads Python packages from PyPI on every start; fails without access (`Failed to download pytest==8.4.2`) |
| User and filesystem | non-root, read-only root filesystem, Pod Security `restricted` | root; as non-root it fails with `Permission denied: '/app/supervisord.log'` |
| Provider API keys | Envoy admin API on localhost only | Envoy admin API on all interfaces; `/config_dump` returns the API keys to anyone who can reach the pod |
| Rolling upgrades | 0 failed requests and 0 cut streams (tested) | open connections are cut when a pod stops |
| Several replicas | PostgreSQL conversation state (table created by the chart) and Redis session cache from two values | write the config, create the table by hand |
| Memory | Envoy workers capped (2 by default) | one Envoy worker per CPU of the node, about 10 MiB each |
| Access logs | to stdout | to files in the container that are never rotated |
| Invalid configuration | pod fails with the validation error | same |
| Guards | refuses memory state with several replicas and TLS-only PostgreSQL URLs | – |

## Deployment modes

### Single pod (default)

Good for development and for gateways that don't need conversation state. Put your API keys in a Secret and reference them:

```yaml
config:
  model_providers:
    - model: openai/gpt-4o-mini
      access_key: $OPENAI_API_KEY
      default: true
    - model: anthropic/claude-sonnet-4-5
      access_key: $ANTHROPIC_API_KEY
existingSecret: llm-keys   # kubectl create secret generic llm-keys --from-literal=OPENAI_API_KEY=... --from-literal=ANTHROPIC_API_KEY=...
```

### Several replicas (high availability)

Plano itself is stateless, but two features keep state in the pod unless you share it:

- **Conversation state** for the OpenAI Responses API (`previous_response_id`). Plano keeps it for providers it translates to (e.g. Anthropic, DeepSeek); OpenAI's own Responses API keeps its state at OpenAI. Share it with `stateStorage.postgres`; the chart creates Plano's `conversation_states` table in a Job before every install and upgrade.
- **Model affinity** (`X-Model-Affinity` header), which pins a session to the model the router picked. Share it with `sessionCache.redis`.

```yaml
replicaCount: 3
existingSecret: llm-keys
stateStorage:
  postgres:
    existingSecret: plano-postgres   # key "postgres-url": postgresql://user:password@host:5432/db
sessionCache:
  redis:
    existingSecret: plano-redis      # key "redis-url": redis://:password@host:6379
podDisruptionBudget:
  enabled: true
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: plano
        app.kubernetes.io/instance: plano
```

**Tested in kind:** a chain of 5 Responses API requests alternated between 2 pods, and each pod continued the conversation the other one stored. Both pods connected to Redis. The chart refuses `state_storage: {type: memory}` with more than one replica, because `previous_response_id` would only work on the pod that stored it.

Instead of `replicaCount`, `autoscaling.enabled=true` creates a HorizontalPodAutoscaler on CPU.

## Configuring Plano

`config` is written to `plano_config.yaml` as is; see Plano's [configuration reference](https://docs.planoai.dev/resources/configuration_reference.html). Values like `$OPENAI_API_KEY` are replaced with environment variables when Plano starts. Set them with:

- `secretEnv`: a map stored in a Secret created by the chart (convenient, but the keys end up in your values);
- `existingSecret`: a Secret whose keys all become environment variables (recommended);
- `extraEnv` / `extraEnvFrom`: anything else, e.g. `OTEL_TRACING_GRPC_ENDPOINT` for tracing.

Your `config` is merged with the chart's default: maps merge, lists (`listeners`, `model_providers`) replace. The pods restart when `config` or `secretEnv` changes.

**Ports** follow the listeners in `config`: the model listener becomes the `llm` port (default 12000, also used by the probes), each other listener gets a port named after it. Plano also runs its LLM gateway on 12000 when you only configure agent listeners. An agent listener as in Plano's agent orchestration guide:

```yaml
config:
  agents:
    - id: rag_agent
      url: http://rag-agent:8080
  model_providers:
    - model: openai/gpt-4o-mini
      access_key: $OPENAI_API_KEY
      default: true
  listeners:
    - type: agent
      name: agent_1
      port: 8001
      router: plano_orchestrator_v1
      agents:
        - id: rag_agent
          description: virtual assistant for retrieval augmented generation tasks
existingSecret: llm-keys
```

This gives the Service the ports `llm` (12000) and `agent-1` (8001). **Tested in kind** with this listener: both ports answer `/healthz` and `helm test` passes.

**Your own ConfigMap:** keep `plano_config.yaml` elsewhere (e.g. managed by GitOps) and set the ports yourself:

```yaml
existingConfigMap: my-plano-config   # key plano_config.yaml
ports:
  - name: llm
    port: 12000
existingSecret: llm-keys
```

Plano reads it at startup; run `kubectl rollout restart deployment/plano` after changing it. `stateStorage` and `sessionCache` can't be used here; put `state_storage` and `routing.session_cache` in your file.

**Files** such as a CA bundle for `upstream_tls_ca_path` go in with `extraVolumes` and `extraVolumeMounts`.

## Connecting clients

Point any OpenAI SDK at the `llm` port:

```text
http://plano.<namespace>.svc:12000/v1
```

The client's API key is replaced with the provider key from your config (tested), so clients can send any value. Plano also accepts Anthropic's Messages API (`/v1/messages`) and the OpenAI Responses API (`/v1/responses`) on the same port. The install notes print the URL of every listener.

## Security

**Plano does not authenticate clients.** Anyone who can reach the Service spends your provider budget. Keep the Service internal (`ClusterIP`, the default) and restrict who can connect:

```yaml
networkPolicy:
  enabled: true
  from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: my-agents
```

Pods with the label `<full name>-client: "true"` are always allowed (`plano-client` for a release named `plano`; the install notes print it); `helm test` uses that label. The policy also closes the ports Plano opens for its own use (brightstaff 9091, Envoy 10001, 11000, 12001). **Tested in kind:** a pod without the label couldn't connect to the gateway, a labelled one could, and neither reached the internal ports or the Envoy admin API. If you expose Plano with `ingress.enabled`, put authentication in front of it.

**Envoy admin API:** the image binds it to all interfaces, and its `/config_dump` contains the provider API keys (tested: the key appeared 12 times). The chart binds it to `127.0.0.1`. `envoy.adminOnAllInterfaces=true` restores the image's behaviour; don't use it with real keys.

## Upgrades and shutdown

Plano stops at once when its pod is stopped and cuts open connections. The chart therefore keeps a stopping pod serving for `shutdownDelaySeconds` (default 20) while Kubernetes removes it from the Service. Raise it (and `terminationGracePeriodSeconds`) to the length of your longest responses.

**Tested in kind** (2 replicas, rolling `helm upgrade`, a client sending short chat completions and 10-second streams for 100 seconds):

| `shutdownDelaySeconds` | Failed requests | Cut streams |
|---|---|---|
| 20 (default) | 0 of 720 | 0 of 30 |
| 0 | 2 of 282 | 9 of 39 |

An upgrade from Plano 0.4.36 to 0.4.37 with the chart was also tested.

## Prometheus metrics

Plano's brightstaff service exports Prometheus metrics on port 9092 (`/metrics`): requests, upstream LLM calls by provider, model and status, tokens, time to first token and routing decisions. The port is on the Service by default. For the Prometheus Operator:

```yaml
metrics:
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

## Sizing

Measured with Plano 0.4.37 at idle: **283 MiB with 1 Envoy worker, 290 MiB with 2, 316 MiB with 4, 431 MiB with 16.** Without a limit, Envoy starts one worker per CPU of the node, not of the pod, so the same pod needs more memory on bigger nodes. The chart sets `envoy.concurrency: 2`; raise it together with the memory limit for more throughput per pod, or add replicas.

A new pod is ready 1 to 3 seconds after it starts. The very first start in a new kind cluster took 67 seconds, while Envoy resolved the providers' hostnames; the startup probe allows 3 minutes.

## FAQ

**Is there an official Plano Helm chart?** No. Plano publishes the container image and a plain Deployment example, and Artifact Hub had no Plano chart when this one was published. This chart uses the official image.

**Why does Plano fail with `Failed to download pytest==8.4.2` or `Failed to fetch: https://files.pythonhosted.org`?** The official image installs Python packages from PyPI on every start (`uv run`), so it can't start in clusters without internet access. The chart starts Plano with the packages already in the image.

**Why does Plano fail with `PermissionError: [Errno 13] Permission denied: '/app/supervisord.log'`?** The image only runs as root. The chart runs it as user 10001 with its own start script.

**Why does Plano fail with `Failed to connect to database: error performing TLS handshake`?** Plano 0.4.37 can't use TLS for PostgreSQL, so `sslmode=require` and servers that enforce TLS fail. See [Known issues](#known-issues).

**Why does Plano log `Table 'conversation_states' does not exist`?** Plano doesn't create its table; without it, requests still succeed but no conversation state is stored. The chart creates the table with `stateStorage.postgres` (`createTable.enabled`, on by default).

**Why does `previous_response_id` fail with `Conversation state not found` behind a load balancer?** The state is in one pod's memory. Use `stateStorage.postgres`.

**How do I run Plano highly available on Kubernetes?** See [Several replicas](#several-replicas-high-availability).

**How do I monitor Plano with Prometheus?** See [Prometheus metrics](#prometheus-metrics).

**How do I keep my API keys safe?** Use `existingSecret`, keep `envoy.adminOnAllInterfaces=false`, and enable the NetworkPolicy (see [Security](#security)).

## Known issues

These are in Plano 0.4.37, not in the chart.

- **PostgreSQL without TLS only.** Plano connects to PostgreSQL without TLS. Databases that enforce TLS refuse it, and `sslmode=require` fails with `error performing TLS handshake`; the chart refuses such URLs. Use a database that accepts non-TLS connections from the cluster, ideally through a private network.
- **No reconnect to PostgreSQL.** Plano opens one database connection at startup. When it drops (database restart or failover), Plano doesn't reconnect: requests still succeed, but without loading or storing conversation state, and the pods log `Storage error: ... connection closed`. Restart Plano afterwards with `kubectl rollout restart deployment/plano`; an alert on that log line catches it. Tested by terminating the connections in PostgreSQL.
- **Model affinity with Redis** was tested only up to the connection (both pods connected), not with Plano's router model, which runs outside the cluster.
- Plano's Envoy configuration contains a cluster for the host `mistral_7b_instruct`, which never resolves. It causes failed DNS lookups every few seconds but no errors.
- `logLevel` sets the level of brightstaff and Envoy's WASM filters; Envoy's own messages stay at `info`.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler. Needs the same shared state as `replicaCount` > 1. |
| autoscaling.maxReplicas | int | `10` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `70` | Target average CPU utilization in percent. |
| config | object | an OpenAI model listener on port 12000 | Plano configuration, written to `plano_config.yaml` (see Plano's configuration reference: https://docs.planoai.dev/resources/configuration_reference.html). Values like `$OPENAI_API_KEY` are replaced with environment variables at startup; put the keys in `secretEnv` or `existingSecret`. Your `config` is merged with this default: maps merge, lists (`listeners`, `model_providers`) replace. Ignored when `existingConfigMap` is set. |
| envoy.adminOnAllInterfaces | bool | `false` | Bind Envoy's admin API (port 9901) to all interfaces, as the image does. Its `/config_dump` returns the provider API keys, so the chart keeps it on localhost. |
| envoy.concurrency | int | `2` | Envoy worker threads. Envoy otherwise starts one per CPU of the node (not of the pod), and each one adds about 10 MiB, measured with Plano 0.4.37. Raise it for more throughput per pod. |
| existingConfigMap | string | `""` | Name of an existing ConfigMap with your `plano_config.yaml`. Replaces `config`. Then set `ports`, and `stateStorage`/`sessionCache` can't be used (configure them in your file). |
| existingConfigMapKey | string | `"plano_config.yaml"` | Key in `existingConfigMap` that holds the configuration. |
| existingSecret | string | `""` | Name of an existing Secret whose keys all become environment variables (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`). |
| extraEnv | list | `[]` | Extra environment variables, e.g. `OTEL_TRACING_GRPC_ENDPOINT` (OpenTelemetry collector for traces). |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Plano container. |
| extraVolumes | list | `[]` | Extra volumes, e.g. a CA bundle for `upstream_tls_ca_path` in `config`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"katanemo/plano"` | Image repository. Defaults to Plano's official image. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the `llm` port. Plano doesn't authenticate clients; protect the Ingress (see "Security"). |
| ingress.hosts | list | `[{"host":"plano.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/healthz","port":"llm"},"periodSeconds":10}` | Liveness probe. |
| logLevel | string | `"info"` | Log level of brightstaff and Envoy's WASM filters (`debug`, `info`, `warn`, `error`). |
| metrics.enabled | bool | `true` | Add brightstaff's Prometheus endpoint (port 9092, `/metrics`) to the Service. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the label your Prometheus selects ServiceMonitors by. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy that only allows traffic to the listener ports and the metrics port. Plano also listens on internal ports (brightstaff 9091, Envoy 10001, 11000, 12001) on all interfaces; this closes them. |
| networkPolicy.from | list | `[]` | Sources allowed to reach the listener ports (NetworkPolicy `from` entries). Empty: any pod and address. |
| networkPolicy.metricsFrom | list | `[]` | Sources allowed to reach the metrics port. Empty: any pod and address. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podDisruptionBudget.enabled | bool | `false` | Create a PodDisruptionBudget. |
| podDisruptionBudget.maxUnavailable | int | `1` | Maximum unavailable pods. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The official image runs as root; the chart runs it as a non-root user. |
| ports | list | `[]` | Container and Service ports, as a list of `name`/`port`. Empty: one port per listener in `config` (`llm` for the model listener, which also serves the probes). Required with `existingConfigMap`; name the model listener's port `llm`. |
| readinessProbe | object | `{"failureThreshold":2,"httpGet":{"path":"/healthz","port":"llm"},"periodSeconds":5}` | Readiness probe. |
| replicaCount | int | `1` | Number of Plano pods. More than 1 needs shared conversation state if you use it: `stateStorage.postgres` instead of `state_storage: {type: memory}` (the chart refuses that combination). See "Running several replicas". |
| resources | object | `{"limits":{"memory":"768Mi"},"requests":{"cpu":"100m","memory":"384Mi"}}` | Resources for the Plano container. Idle memory is about 290 MiB with 2 Envoy workers (measured with Plano 0.4.37). |
| secretEnv | object | `{}` | Environment variables stored in a Secret created by the chart, e.g. provider API keys referenced as `$OPENAI_API_KEY` in `config`. For production use `existingSecret`. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Plano does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| sessionCache.redis.existingSecret | string | `""` | Name of an existing Secret that holds the Redis URL. |
| sessionCache.redis.existingSecretKey | string | `"redis-url"` | Key in `existingSecret` that holds the Redis URL. |
| sessionCache.redis.url | string | `""` | Redis URL, e.g. `redis://:password@redis:6379` or `rediss://` for TLS. Stored in a Secret created by the chart; ignored when `existingSecret` is set. When set, the chart adds `routing.session_cache` to `config`. |
| shutdownDelaySeconds | int | `20` | Seconds a stopping pod keeps serving before Plano is stopped, so that it leaves the Service endpoints first and running requests (streamed LLM responses) can finish. Plano itself stops at once and cuts open connections. |
| startupProbe | object | `{"failureThreshold":90,"httpGet":{"path":"/healthz","port":"llm"},"periodSeconds":2}` | Startup probe. `/healthz` on the model listener is answered by Envoy once it has resolved the providers' hostnames. Allows 3 minutes: a first start in a new kind cluster took 67 seconds, later starts 1-3 seconds. |
| stateStorage.postgres.createTable.activeDeadlineSeconds | int | `300` | Maximum runtime of the Job in seconds. |
| stateStorage.postgres.createTable.backoffLimit | int | `3` | Retries of the Job before the install/upgrade fails. |
| stateStorage.postgres.createTable.enabled | bool | `true` | Create Plano's `conversation_states` table (`CREATE TABLE IF NOT EXISTS`) in a Job before every install and upgrade. Plano only checks that the table exists. |
| stateStorage.postgres.createTable.image | string | `"postgres:18-alpine"` | Image with `psql` for the Job. The Plano image has no PostgreSQL client. |
| stateStorage.postgres.createTable.resources | object | `{}` | Resources for the Job. |
| stateStorage.postgres.existingSecret | string | `""` | Name of an existing Secret that holds the connection string. |
| stateStorage.postgres.existingSecretKey | string | `"postgres-url"` | Key in `existingSecret` that holds the connection string. |
| stateStorage.postgres.url | string | `""` | PostgreSQL connection string `postgresql://user:password@host:5432/db`. URL-encode special characters in the password. Plano connects without TLS (see "Known issues"). Stored in a Secret created by the chart; ignored when `existingSecret` is set. When set, the chart adds `state_storage` to `config`. |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after the pod is asked to stop. Must be larger than `shutdownDelaySeconds`. |
| tests.chatCompletion.enabled | bool | `false` | Also send a chat completion in `helm test`. This calls your default model provider and costs a request. |
| tests.chatCompletion.model | string | `"openai/gpt-4o-mini"` | Model for the test request. |
| tmpSizeLimit | string | `"64Mi"` | Size limit of the writable `/tmp` volume (rendered configs). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
