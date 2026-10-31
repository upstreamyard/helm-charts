# Parse Server Helm chart

![Version: 0.1.6](https://img.shields.io/badge/Version-0.1.6-informational?style=flat-square) ![AppVersion: 9.10.7](https://img.shields.io/badge/AppVersion-9.10.7-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for [Parse Server](https://github.com/parse-community/parse-server), the open-source backend for mobile, web and IoT apps. It uses the Parse community's official image [`parseplatform/parse-server`](https://hub.docker.com/r/parseplatform/parse-server).

> Community chart by **upstreamyard**, not an official Parse Server chart. Parse Server is © its contributors, licensed under Apache-2.0.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install parse-server upstreamyard/parse-server \
  --set parse.appId=myapp \
  --set parse.masterKey=$(openssl rand -hex 32) \
  --set parse.publicServerURL=https://api.example.com/parse \
  --set database.uri='mongodb://user:password@your-mongo:27017/parse'
```

Or from the OCI registry:

```bash
helm install parse-server oci://ghcr.io/upstreamyard/charts/parse-server --set parse.appId=myapp ...
```

Clients (the Parse SDKs) then connect to `parse.publicServerURL` with the application ID.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install parse-server upstreamyard/parse-server --verify --keyring upstreamyard.gpg --set ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **MongoDB** (required), in a version Parse Server supports (see Parse Server's compatibility table). Parse Server also supports PostgreSQL with PostGIS, but this chart is only tested with MongoDB. This chart does not deploy a database.
- An Ingress controller or load balancer if apps outside the cluster connect.

## What the chart does

- **Configuration:** Parse Server reads `PARSE_SERVER_*` environment variables. The chart sets the application ID, master key, database URI, mount path `/parse` and the public URL; add other top-level options with `extraEnv`. Database options (`databaseOptions.*`) are only read as JSON from `PARSE_SERVER_DATABASE_OPTIONS`, which the chart builds from `parse.schemaCacheTtl` and `parse.enableSchemaHooks`; the per-option variable names in Parse Server's option list have no effect.
- **No migrations:** Parse Server creates its collections and indexes itself on startup.
- **Probes:** `/parse/health`, which returns 200 only once Parse Server is connected to the database and initialized.
- **Several replicas:** Parse Server keeps no local state (files go to MongoDB GridFS by default), so `replicaCount` can be raised. Each pod caches the database schema, though: without help, a class created through one pod stays unknown to the others until they restart (clients get `Permission denied`). The chart therefore sets `parse.schemaCacheTtl` (60 s); in our tests the other pods then saw new classes right away. With a MongoDB replica set you can also set `parse.enableSchemaHooks`. LiveQuery is not set up by this chart.
- **Shutdown:** Node.js exits immediately on `SIGTERM`, so the pod first waits `preStopSleepSeconds` (5) while it's removed from the Service. In our test, a rolling update under constant requests had no failed request.
- **Security:** runs as the image's `node` user (UID 1000) with a read-only root filesystem (logs go to an emptyDir), drops all capabilities, and doesn't mount a ServiceAccount token.
- **`helm test`** checks `/parse/health` and a query with the application ID through the Service.

## Parse Server's secure defaults

Parse Server 9 is strict out of the box, and the chart keeps it that way:

- **Master key** works only from localhost, i.e. inside the pod (Cloud Code, `kubectl exec`, and `kubectl port-forward`, whose traffic arrives as localhost). Requests through the Service or Ingress get `unauthorized`. If Parse Dashboard or another service needs it, set `parse.masterKeyIps` to their IP range.
- **Clients can't create classes** (`Permission denied`). Create classes with the master key or in Parse Dashboard, or set `PARSE_SERVER_ALLOW_CLIENT_CLASS_CREATION=true` through `extraEnv` for development.
- **Public file uploads are off** (`File upload by public is disabled.`); see the `fileUpload` options.

## Cloud Code

Write your Cloud Code (functions, triggers, background jobs) directly in the values. The chart stores it in a ConfigMap and loads it:

```yaml
cloudCode:
  enabled: true
  main: |
    Parse.Cloud.define('hello', req => `hello ${req.params.name || 'world'}`);
```

For code split across several files, create your own ConfigMap and set `cloudCode.existingConfigMap` instead; the file named in `cloudCode.entrypoint` (`main.js`) is loaded. Cloud Code that needs npm packages beyond Parse Server's own needs an image built `FROM parseplatform/parse-server`; set `image.repository` and `image.tag` to it.

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
parse:
  appId: myapp
  existingSecret: parse                 # key: master-key
  publicServerURL: https://api.example.com/parse
database:
  existingSecret: parse-db              # key: database-uri
cloudCode:
  enabled: true
  main: |                              # or existingConfigMap: <your ConfigMap>
    Parse.Cloud.define('hello', req => `hello ${req.params.name || 'world'}`);
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 20m
  hosts:
    - host: api.example.com
      paths: [{ path: /parse, pathType: Prefix }]
  tls:
    - hosts: [api.example.com]
      secretName: api-tls
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| cloudCode.enabled | bool | `false` | Load Cloud Code (functions, triggers, jobs). Write it in `main` and the chart creates the ConfigMap, or use your own with `existingConfigMap`. Mounted at `/parse-server/cloud`. |
| cloudCode.entrypoint | string | `"main.js"` | File that Parse Server loads (`PARSE_SERVER_CLOUD`). |
| cloudCode.existingConfigMap | string | `""` | Name of your own ConfigMap with Cloud Code files, e.g. for code split across several files (`entrypoint` is loaded). Takes precedence over `main`. |
| cloudCode.main | string | `""` | Content of `main.js`. The chart creates a ConfigMap from it. Ignored when `existingConfigMap` is set. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the connection string (recommended for production). |
| database.existingSecretKey | string | `"database-uri"` | Key in `existingSecret` that holds the connection string. |
| database.uri | string | `""` | Connection string, e.g. `mongodb://user:password@mongo:27017/parse`. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| extraEnv | list | `[]` | Extra environment variables. Top-level Parse Server options can be set as `PARSE_SERVER_*` (nested `databaseOptions` only as JSON in `PARSE_SERVER_DATABASE_OPTIONS`, which this chart sets from `parse.schemaCacheTtl` and `parse.enableSchemaHooks`), e.g. `PARSE_SERVER_ALLOW_CLIENT_CLASS_CREATION`, `PARSE_SERVER_LOG_LEVEL`. See https://github.com/parse-community/parse-server/blob/alpha/src/Options/Definitions.js |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps, e.g. email adapter or push credentials. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Parse Server container. |
| extraVolumes | list | `[]` | Extra volumes for the pods. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"parseplatform/parse-server"` | Image repository. The Parse community's official image. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. Allow request bodies as large as your file uploads, e.g. `nginx.ingress.kubernetes.io/proxy-body-size: 20m`. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress. |
| ingress.hosts | list | `[{"host":"api.example.com","paths":[{"path":"/parse","pathType":"Prefix"}]}]` | Ingress hosts and paths. Route `/parse` (or `/`) to the Service; the host should match `parse.publicServerURL`. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/parse/health","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on `/parse/health`. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| parse.appId | string | `""` | Application ID (`PARSE_SERVER_APPLICATION_ID`), sent by clients in `X-Parse-Application-Id`. Required. |
| parse.enableSchemaHooks | bool | `false` | Propagate schema changes to all pods at once through MongoDB change streams (`databaseOptions.enableSchemaHooks`). Needs a MongoDB replica set. |
| parse.existingSecret | string | `""` | Name of an existing Secret that holds the master key. |
| parse.existingSecretKey | string | `"master-key"` | Key in `existingSecret` that holds the master key. |
| parse.masterKey | string | `""` | Master key (`PARSE_SERVER_MASTER_KEY`), e.g. from `openssl rand -hex 32`. Stored in a Secret created by this chart. Required unless `existingSecret` is set. |
| parse.masterKeyIps | string | `""` | IPs or CIDR ranges allowed to use the master key, comma-separated (`PARSE_SERVER_MASTER_KEY_IPS`). Empty keeps Parse Server's default: only localhost, i.e. Cloud Code and `kubectl exec`. Set your Parse Dashboard's pod range here if it connects with the master key. |
| parse.publicServerURL | string | `""` | Public URL of the API, including the `/parse` path, e.g. `https://api.example.com/parse` (`PARSE_PUBLIC_SERVER_URL`). Used in file URLs and emails. Required. |
| parse.schemaCacheTtl | int | `60` | Seconds after which a pod re-reads the database schema (`databaseOptions.schemaCacheTtl`). Without it, a class or field created through one pod stays unknown to the other pods until they restart. Empty disables it (Parse Server's default, fine for 1 replica). |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":1000,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as the `node` user, UID 1000. |
| preStopSleepSeconds | int | `5` | Seconds to wait before the container gets SIGTERM, so the pod is removed from the Service first (Node.js exits immediately on SIGTERM). 0 disables it. |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/parse/health","port":"http"},"periodSeconds":5,"timeoutSeconds":3}` | Readiness probe on `/parse/health`. |
| replicaCount | int | `1` | Number of Parse Server pods. Parse Server keeps no local state, so it scales horizontally (LiveQuery is not set up by this chart). |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources for the Parse Server container. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. Logs go to an emptyDir, so the root filesystem is read-only. |
| service.port | int | `80` | Service port. Parse Server listens on 1337 inside the container. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Parse Server does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/parse/health","port":"http"},"periodSeconds":2,"timeoutSeconds":5}` | Startup probe. `/parse/health` returns 200 only once Parse Server is connected and initialized. |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after SIGTERM. |
| tolerations | list | `[]` | Tolerations. |
