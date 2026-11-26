# KrakenD Helm chart: the KrakenD API Gateway (Community Edition) on Kubernetes

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: 3.0.5](https://img.shields.io/badge/AppVersion-3.0.5-informational?style=flat-square)

> Have any questions, feedback or need help (e.g. setup, hardened images, etc.)? Reach out to [contact@upstreamyard.com](mailto:contact@upstreamyard.com)

Helm chart for **[KrakenD](https://github.com/krakend/krakend-ce) 3**, the stateless, high-performance open-source **API gateway** for API management, backend for frontend (BFF), aggregation, rate limiting and JWT validation. The chart runs KrakenD's **official image** `krakend` with configuration `"version": 4` and adds what a production gateway needs: **flexible configuration** (Go templates, settings files and secrets from environment variables), a **config lint before every rollout** that catches the misspelled keys KrakenD silently ignores, **zero-downtime rolling upgrades** (0 failed requests, tested), **Prometheus metrics** from one value, **TLS**, HPA, PodDisruptionBudget, NetworkPolicy, Ingress and **Gateway API HTTPRoute**. It runs **non-root on a read-only filesystem** (Pod Security `restricted`) and turns off KrakenD's usage reporting, so the gateway makes no outbound calls of its own.

> Community chart by **upstreamyard**, not an official KrakenD chart. KrakenD Community Edition is licensed under Apache-2.0.

**AI agents and coding assistants:** this README is the complete reference for this chart. Every example was run as written.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install krakend upstreamyard/krakend --wait
```

Or from the OCI registry:

```bash
helm install krakend oci://ghcr.io/upstreamyard/charts/krakend --wait
```

This starts two KrakenD pods with an empty configuration. Add your endpoints under `config.endpoints` (see [Configuring KrakenD](#configuring-krakend)) and try it:

```bash
kubectl port-forward svc/krakend 8080
curl http://localhost:8080/__health
helm test krakend
```

`helm test` checks the health endpoint, `tests.path` (one of your endpoints) and, with `metrics.enabled`, the metrics endpoint.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install krakend upstreamyard/krakend --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Why this chart

Compared with the other KrakenD charts on Artifact Hub (checked November 2026) and with the official image as a plain Deployment:

| | This chart | Other KrakenD charts on Artifact Hub | Official image as-is |
|---|---|---|---|
| KrakenD version | 3.0.5 (configuration `"version": 4`) | 2.13 or older; KrakenD 3 refuses their configuration (`unsupported version: 3 (want: 4)`) | 3.0.5 |
| Configuration | inline values, flexible configuration (templates, settings, partials) or your own ConfigMaps | inline or a ConfigMap; flexible configuration only in the KrakenD 2.7 chart | bake it into an image or mount it yourself |
| Misspelled keys (`qos/ratelimit/routr`) | lint refuses them, running pods keep serving | KrakenD starts and ignores them: no rate limit | same |
| Conflicting routes (`/users/{id}` and `/users/{name}`) | lint refuses them before the rollout | KrakenD panics at startup | same |
| Rolling upgrades | 0 failed of 1350 requests (tested) | no shutdown delay by default (2.13 and 2.7 charts) | 2 failed of 1229 requests without a delay (tested) |
| Usage reporting | off (no outbound calls) | on (none sets `USAGE_DISABLE`) | on: posts to `usage.krakend.io` 5 s after start |
| Metrics | Prometheus exporter, Service port and ServiceMonitor from `metrics.enabled` | ServiceMonitor in the 2.7 chart; exporter configured by you | configure it yourself |
| Exposure | Service, Ingress, Gateway API HTTPRoute, TLS from a Secret | Service, Ingress; TLS in the 2.13 chart | – |
| User and filesystem | UID 1000, read-only root filesystem, Pod Security `restricted` (tested) | non-root in the 2.13 and 2.7 charts | starts as root, then switches to UID 1000 |

## Deployment modes

### Inline configuration (default)

Write KrakenD's configuration as YAML under `config`; the chart turns it into `krakend.json`:

```yaml
config:
  endpoints:
    - endpoint: /v1/users/{id}
      method: GET
      backend:
        - host: ["http://users.default.svc:8080"]
          url_pattern: /users/{id}
      extra_config:
        qos/ratelimit/router:
          max_rate: 100
          every: 1s
    - endpoint: /v1/orders
      method: GET
      backend:
        - host: ["http://orders.default.svc:8080"]
          url_pattern: /orders
      extra_config:
        auth/validator:
          alg: RS256
          jwk_url: https://auth.example.com/.well-known/jwks.json
          cache: true
```

Your `config` is merged with the chart's default (`version: 4`, a 3-second `timeout`, version header hidden, health checks not logged): maps merge, lists such as `endpoints` replace. Set the port with `port`, not in `config`.

### Flexible configuration (templates, settings and secrets)

For bigger gateways and for secrets, use KrakenD's flexible configuration. `template` is a Go template; `settings` become JSON files you read as `.<file>.<field>`, `partials` are inserted as-is with `include`, `templates` hold sub-templates, and `env` reads environment variables, e.g. from a Secret:

```yaml
flexibleConfig:
  enabled: true
  template: |
    {
      "version": 4,
      "name": "{{ env "GATEWAY_NAME" }}",
      "timeout": "3s",
      "endpoints": [
        {{- range $i, $svc := .services.list }}
        {{- if $i }},{{ end }}
        {
          "endpoint": "/{{ $svc.name }}/{id}",
          "backend": [{
            "host": ["{{ $svc.url }}"],
            "url_pattern": "/{{ $svc.name }}/{id}",
            "extra_config": {{ template "api-key.tmpl" }}
          }],
          "extra_config": {{ include "ratelimit.json" }}
        }
        {{- end }}
      ]
    }
  settings:
    services:
      list:
        - name: users
          url: http://users.default.svc:8080
        - name: orders
          url: http://orders.default.svc:8080
  partials:
    ratelimit.json: |
      {"qos/ratelimit/router": {"max_rate": 100, "every": "1s"}}
  templates:
    api-key.tmpl: |
      {{ define "api-key.tmpl" }}{"modifier/martian": {"header.Modifier": {"scope": ["request"], "name": "X-Api-Key", "value": "{{ env "BACKEND_API_KEY" }}"}}}{{ end }}
existingSecret: krakend-env   # kubectl create secret generic krakend-env --from-literal=GATEWAY_NAME=public-api --from-literal=BACKEND_API_KEY=...
```

**Tested in kind:** both endpoints were generated, the lint passed, and the backend received the `X-Api-Key` header from the Secret.

Partials are inserted without being rendered, so `env` calls belong in `template` or in a sub-template under `templates`, as the API key above (tested: an `env` call in a partial stays literal text).

### Your own ConfigMaps (GitOps)

Keep the configuration in ConfigMaps managed elsewhere:

```yaml
flexibleConfig:
  enabled: true
  existingSettingsConfigMap: krakend-settings   # one <name>.json per settings file
existingConfigMap: krakend-config               # key krakend.tmpl
existingSecret: krakend-env
```

Without `flexibleConfig.enabled`, `existingConfigMap` holds a plain `krakend.json`. KrakenD reads the files at startup only; run `kubectl rollout restart deployment/krakend` after changing them (the lint checks the new version first). Settings, partials and templates live in `/etc/krakend/settings`, `/etc/krakend/partials` and `/etc/krakend/templates`.

### High availability and autoscaling

KrakenD is stateless, so every pod serves every request. The chart runs 2 pods by default, spread across nodes, with a PodDisruptionBudget. For more:

```yaml
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: krakend
        app.kubernetes.io/instance: krakend
```

**Rate limits count per pod.** With `max_rate: 2`, one pod accepted 3 of 10 requests in a burst, and two pods behind the Service accepted 6 of 20 (tested). Divide your limit by the number of pods, or keep the pod count fixed.

## Configuring KrakenD

See KrakenD's [configuration reference](https://www.krakend.io/docs/configuration/structure/) for endpoints, backends and components (`extra_config`).

- **Environment overrides:** KrakenD reads `KRAKEND_<KEY>` for root-level settings, e.g. `KRAKEND_TIMEOUT` (tested) or `KRAKEND_NAME`, set with `extraEnv`. They win over the configuration file. The chart sets `KRAKEND_PORT` from `port`.
- **Secrets:** put them in a Secret (`existingSecret`, or `secretEnv` for tests) and read them with `env` in a flexible configuration. The plain `config` can't read environment variables, except the `KRAKEND_*` overrides.
- **Files** such as a local JWK set (`jwk_local_path`) or a CA bundle go in with `extraVolumes` and `extraVolumeMounts`; they are mounted in the lint container too.
- **Restarts:** pods restart when `config`, `flexibleConfig` or `secretEnv` change.

### The config lint

Before KrakenD starts, an init container runs `krakend check --lint-no-network --test-gin-routes` against KrakenD's built-in schema. KrakenD itself ignores unknown keys, so a typo in a component name means the component is off. **Tested in kind:** a `helm upgrade` with `qos/ratelimit/routr` left both running pods serving while the new pod stopped with:

```text
ERROR linting the configuration file:	jsonschema validation failed with 'file:///etc/krakend/schema.json#'
- at '/endpoints/0/extra_config': additional properties 'qos/ratelimit/routr' not allowed
```

Without the lint, the same configuration ran without any rate limit. The route test also refuses conflicting routes, which make KrakenD panic. `lint.enabled=false` turns it off.

For a security review of your configuration, run KrakenD's audit locally, e.g. `docker run --rm -v $PWD/krakend.json:/etc/krakend/krakend.json krakend:3.0.5 audit -c krakend.json`.

## Connecting clients

```text
http://krakend.<namespace>.svc:8080
```

With `tls.enabled` the same address speaks HTTPS. The install notes print the URL for your release.

**From outside the cluster**, use one of:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: api.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts: [api.example.com]
      secretName: api-example-com-tls
```

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: public
      namespace: gateway-system
  hostnames: ["api.example.com"]
```

or `service.type: LoadBalancer` (with `service.externalTrafficPolicy: Local` to keep client IPs).

## TLS

KrakenD can terminate TLS itself, e.g. for end-to-end encryption behind a load balancer:

```yaml
tls:
  enabled: true
  existingSecret: krakend-tls   # kubernetes.io/tls, e.g. from cert-manager
```

The chart adds `tls.keys` to the configuration and switches the probes to HTTPS. KrakenD then serves HTTPS only; plain HTTP gets `400 Bad Request` (tested). With `flexibleConfig` or `existingConfigMap`, add the `tls` block yourself; the certificate is at `/etc/krakend/tls/tls.crt` and `/etc/krakend/tls/tls.key`.

## Upgrades and shutdown

KrakenD refuses new connections as soon as it gets SIGTERM, then finishes running requests (tested with a 5-second request). Kubernetes still routes requests to a stopping pod for a moment, so the chart keeps the pod serving for `shutdownDelaySeconds` (default 10) first. Keep `terminationGracePeriodSeconds` above that delay plus your longest `timeout`.

**Tested in kind** (2 pods, rolling `helm upgrade` from KrakenD 3.0.4 to 3.0.5, a client sending a request every 50 ms for 70 seconds):

| `shutdownDelaySeconds` | Failed requests |
|---|---|
| 10 (default) | 0 of 1350 |
| 0 | 2 of 1229 |

## Prometheus metrics

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack
```

With `config`, the chart adds a `telemetry/opentelemetry` Prometheus exporter on port 9090 (`/metrics`) unless you configure one. The metrics include `http_server_duration` per route and status code, `krakend_proxy_duration`, `krakend_backend_duration`, the `http_client_*` metrics per backend, and Go and process metrics. With flexible configuration or your own ConfigMap, add the exporter yourself:

```json
"extra_config": {
  "telemetry/opentelemetry": {
    "exporters": {"prometheus": [{"name": "prometheus", "port": 9090}]}
  }
}
```

For traces, add an `otlp` exporter to the same block.

## Security

- **Clients:** KrakenD only checks what your configuration asks for (`auth/validator` for JWT, API keys). Endpoints without it are open to anyone who can reach the Service. `networkPolicy.enabled` with `networkPolicy.from` limits who can connect (tested: other pods time out); pods with the label `<full name>-client: "true"` are always allowed.
- **Usage reporting:** KrakenD sends anonymous usage statistics to `usage.krakend.io` 5 seconds after start (tested). The chart sets `USAGE_DISABLE=1`; `usageStats: true` turns reporting back on.
- **Version header:** KrakenD answers with `X-Krakend: Version 3.0.5`. The default configuration hides the version (`hide_version_header`; the header then reads `Version undefined`, tested).
- **Debug endpoints:** `echo_endpoint` returns every request including `Authorization` headers and cookies; the install notes warn when it's on.
- **Pod security:** UID 1000, read-only root filesystem, no capabilities, `RuntimeDefault` seccomp profile, no ServiceAccount token. All tests ran in a namespace enforcing Pod Security `restricted`.

## Sizing

An idle KrakenD 3.0.5 pod uses about 16 MiB of memory and is ready a few seconds after it starts. The default requests are 100m CPU and 64 MiB, with a 256 MiB memory limit; raise the limit for large responses and many concurrent requests.

## Versions

| `image.tag` | KrakenD | Configuration format |
|---|---|---|
| `3.0.x` (default 3.0.5) | Community Edition 3.0 | `"version": 4` |

KrakenD 2.x images use `"version": 3` and are not supported by this chart. To move a 2.x configuration to KrakenD 3: set `"version": 4`, replace `telemetry/opencensus` and `telemetry/influx` with `telemetry/opentelemetry`, drop `telemetry/metrics` (its port 8090 no longer exists), and remove plugins, which KrakenD CE 3 no longer supports. The lint shows what's left.

## FAQ

**Is there an official KrakenD Helm chart?** No. KrakenD publishes the official image `krakend` on Docker Hub, and the KrakenD charts on Artifact Hub are community charts. This chart uses the official image.

**Why does KrakenD fail with `unsupported version: 3 (want: 4)`?** The configuration is in the KrakenD 2.x format. KrakenD 3 needs `"version": 4`; see [Versions](#versions). The chart refuses `config.version: 3` with the same hint.

**Why is my rate limit (or another component) ignored?** The namespace in `extra_config` is probably misspelled; KrakenD ignores unknown keys. The [config lint](#the-config-lint) refuses them.

**Why does KrakenD answer `503` instead of `429` when rate limited?** That's KrakenD's default status for `qos/ratelimit/router` (tested with 3.0.5).

**Why does KrakenD fail with `panic: ... conflicts with existing wildcard`?** Two endpoints differ only in a parameter name, e.g. `/users/{id}` and `/users/{name}`. The lint shows the conflict before the rollout; use the same parameter name.

**Why does flexible configuration fail with `open /tmp/KrakenD_parsed_config_template_...: read-only file system`?** KrakenD writes the rendered configuration to `/tmp`. The chart mounts a writable `/tmp` (`tmpSizeLimit`); with a read-only root filesystem and no `/tmp` volume it fails.

**How do I run KrakenD highly available on Kubernetes?** See [High availability and autoscaling](#high-availability-and-autoscaling).

**How do I monitor KrakenD with Prometheus?** See [Prometheus metrics](#prometheus-metrics).

**Does KrakenD reload its configuration?** No, KrakenD CE reads it at startup. The chart restarts the pods when the configuration in its values changes; for your own ConfigMaps run `kubectl rollout restart`.

**Does KrakenD call home?** By default it reports usage statistics to `usage.krakend.io`. The chart turns that off.

## Known issues

These are in KrakenD 3.0.5, not in the chart.

- **Partials are not rendered.** `include` inserts a partial as-is, so `env` and other template calls inside a partial stay literal text (this matches KrakenD's documentation). Put them in `template` or in a sub-template under `templates`.
- KrakenD's documentation says `KRAKEND_PORT` has no effect unless the configuration has a `port` key. With 3.0.5 it works without one, and also overrides a `port` in the file (tested); the chart relies on this.
- `helm test` with `tls.enabled` doesn't verify the certificate, because it may not name the Service.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity rules. |
| autoscaling.enabled | bool | `false` | Create a HorizontalPodAutoscaler on CPU. |
| autoscaling.maxReplicas | int | `10` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `70` | Target average CPU utilization in percent. |
| config | object | `version: 4`, no endpoints, version header hidden, health checks not logged | KrakenD configuration, written to `krakend.json` (see KrakenD's configuration reference: https://www.krakend.io/docs/configuration/structure/). Your `config` is merged with this default: maps merge (so `extra_config.router` keeps `hide_version_header` unless you override it), lists such as `endpoints` replace. Ignored when `flexibleConfig.enabled` or `existingConfigMap` is set. Don't set `port` here; use `port`. |
| existingConfigMap | string | `""` | Name of an existing ConfigMap with your configuration (`krakend.json`, or the `krakend.tmpl` template with `flexibleConfig.enabled`). Replaces `config` and `flexibleConfig.template`. KrakenD reads it at startup: restart the pods after changing it. |
| existingConfigMapKey | string | `""` | Key in `existingConfigMap` that holds the configuration. Default: `krakend.json`, or `krakend.tmpl` with `flexibleConfig.enabled`. |
| existingSecret | string | `""` | Name of an existing Secret whose keys all become environment variables. |
| extraEnv | list | `[]` | Extra environment variables, e.g. `KRAKEND_TIMEOUT` or `OTEL_PROPAGATORS`. |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the KrakenD container (and the lint init container). |
| extraVolumes | list | `[]` | Extra volumes, e.g. a JWK file for `auth/validator` (`jwk_local_path`) or a CA bundle. |
| flexibleConfig.enabled | bool | `false` | Use KrakenD's flexible configuration: `template` is a Go template (`krakend.tmpl`) rendered at startup with `settings`, `partials`, `templates` and environment variables (`{{ env "NAME" }}`). Use it to keep secrets out of the configuration and to split big configurations into files. Replaces `config`. |
| flexibleConfig.existingPartialsConfigMap | string | `""` | Existing ConfigMap with partials. Replaces `partials`. |
| flexibleConfig.existingSettingsConfigMap | string | `""` | Existing ConfigMap with settings files (`<name>.json`). Replaces `settings`. |
| flexibleConfig.existingTemplatesConfigMap | string | `""` | Existing ConfigMap with sub-templates. Replaces `templates`. |
| flexibleConfig.partials | object | `{}` | Partials: files inserted as-is with `{{ include "<file>" }}`. Key = file name. |
| flexibleConfig.settings | object | `{}` | Settings files: each key becomes `<key>.json`, available in templates as `{{ .<key>.<field> }}`. |
| flexibleConfig.template | string | `""` | The main template, written to `krakend.tmpl`. Required unless `existingConfigMap` holds it. |
| flexibleConfig.templates | object | `{}` | Sub-templates: Go templates you call with `{{ template "<name>" . }}`. Key = file name (e.g. `endpoint.tmpl`). |
| fullnameOverride | string | `""` | Override the full resource name. |
| httpRoute.annotations | object | `{}` | HTTPRoute annotations. |
| httpRoute.enabled | bool | `false` | Create a Gateway API HTTPRoute. |
| httpRoute.hostnames | list | `[]` | Host names of the route. |
| httpRoute.parentRefs | list | `[]` | Gateways the route attaches to. |
| httpRoute.rules | list | `[]` | Route rules. Empty: everything to KrakenD. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"krakend"` | Image repository. Defaults to KrakenD's official image on Docker Hub. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. The chart supports KrakenD 3.x (configuration `"version": 4`). |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. With `tls.enabled`, tell your controller to talk HTTPS to the pods (ingress-nginx: `nginx.ingress.kubernetes.io/backend-protocol: HTTPS`). |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"api.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| lint.enabled | bool | `true` | Lint the configuration in an init container before KrakenD starts: `krakend check` against the schema built into the image (no network needed) and a test of the routes. KrakenD ignores unknown or misspelled keys at runtime (a misspelled `qos/ratelimit/router` silently means no rate limit); the lint refuses them, so a broken configuration never replaces running pods. |
| lint.resources | object | `{}` | Resources of the lint init container. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/__health","port":"http"},"periodSeconds":10}` | Liveness probe. |
| metrics.enabled | bool | `false` | Expose Prometheus metrics on `metrics.port` (`/metrics`). With `config`, the chart adds a `telemetry/opentelemetry` Prometheus exporter (unless you configure one). With `flexibleConfig` or `existingConfigMap`, add the exporter yourself on this port. |
| metrics.port | int | `9090` | Port of the Prometheus exporter. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the label your Prometheus selects ServiceMonitors by. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| networkPolicy.enabled | bool | `false` | Create a NetworkPolicy for incoming traffic: `port` from `networkPolicy.from`, the metrics port from `networkPolicy.metricsFrom`. Outgoing traffic (to your backends) is not restricted. |
| networkPolicy.from | list | `[]` | Sources allowed to reach the gateway (NetworkPolicy `from` entries). Empty: any pod and address. Pods with the label `<full name>-client: "true"` are always allowed. |
| networkPolicy.metricsFrom | list | `[]` | Sources allowed to reach the metrics port. Empty: any pod and address. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget (only with more than one replica). |
| podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be down at once during voluntary disruptions such as node drains. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. KrakenD's image starts as root and switches to its `krakend` user (UID 1000); the chart starts it as UID 1000 directly. |
| port | int | `8080` | Port KrakenD listens on (set with `KRAKEND_PORT`, which also wins over a `port` in your configuration). The Service uses the same port. |
| priorityClassName | string | `""` | Priority class name. |
| readinessProbe | object | `{"failureThreshold":2,"httpGet":{"path":"/__health","port":"http"},"periodSeconds":5}` | Readiness probe. Uses KrakenD's health endpoint; change `path` if you set `health_path` in your configuration. The scheme follows `tls.enabled`. |
| replicaCount | int | `2` | Number of KrakenD pods. KrakenD is stateless, so any number works; 2 keeps the gateway up while a pod restarts. Rate limits (`qos/ratelimit/*`) count per pod: a limit of 100 req/s allows up to 100 req/s on each pod. Ignored when `autoscaling.enabled` is true. |
| resources | object | `{"limits":{"memory":"256Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}` | Resources for the KrakenD container. Idle memory is about 16 MiB (measured with KrakenD 3.0.5); add memory for large responses and many concurrent requests. |
| secretEnv | object | `{}` | Environment variables stored in a Secret created by the chart, e.g. `JWT_SECRET` for `{{ env "JWT_SECRET" }}` in `flexibleConfig.template`, or `KRAKEND_*` overrides. For production use `existingSecret`. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| service.externalTrafficPolicy | string | `""` | `externalTrafficPolicy` for `LoadBalancer` or `NodePort` (`Local` keeps the client IP). |
| service.nodePort | string | `nil` | Node port when `type` is `NodePort` or `LoadBalancer`. |
| service.port | int | `8080` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. KrakenD does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| shutdownDelaySeconds | int | `10` | Seconds a stopping pod keeps serving before KrakenD gets SIGTERM, so it leaves the Service endpoints first. KrakenD refuses new connections as soon as it gets SIGTERM and then finishes running requests. |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after the pod is asked to stop. Must be larger than `shutdownDelaySeconds` plus your longest request (`timeout` in `config`). |
| tests.path | string | `""` | Extra path that `helm test` requests through the gateway and expects HTTP 200 from, e.g. one of your endpoints. Empty: only the health endpoint. |
| tls.enabled | bool | `false` | Serve HTTPS on `port` with the certificate in `tls.existingSecret` (type `kubernetes.io/tls`). The chart adds `tls.keys` to `config` and switches the probes to HTTPS. KrakenD then serves HTTPS only. With `flexibleConfig` or `existingConfigMap`, add the `tls` block yourself (the certificate is mounted at `/etc/krakend/tls/tls.crt` and `tls.key`). |
| tls.existingSecret | string | `""` | Secret with `tls.crt` and `tls.key`, e.g. from cert-manager. |
| tmpSizeLimit | string | `"64Mi"` | Size limit of the writable `/tmp` volume. Flexible configuration writes the rendered configuration there. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. Empty: the chart spreads pods across nodes when possible (`ScheduleAnyway`). |
| updateStrategy | object | `{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":0},"type":"RollingUpdate"}` | Rolling update strategy of the Deployment. |
| usageStats | bool | `false` | Send KrakenD's anonymous usage statistics to `usage.krakend.io`. KrakenD does this by default, 5 seconds after start; the chart turns it off (`USAGE_DISABLE=1`) so the gateway makes no outbound calls of its own. |
