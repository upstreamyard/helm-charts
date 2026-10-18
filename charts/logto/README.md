# Logto Helm chart

![Version: 0.1.1](https://img.shields.io/badge/Version-0.1.1-informational?style=flat-square) ![AppVersion: 1.45.0](https://img.shields.io/badge/AppVersion-1.45.0-informational?style=flat-square)

Helm chart for [Logto](https://github.com/logto-io/logto), the open-source identity and access management platform: sign-in, OIDC and OAuth 2.0, SSO and multi-tenancy for your apps. It uses Logto's official image [`svhd/logto`](https://hub.docker.com/r/svhd/logto).

> Community chart by **upstreamyard**, not an official Logto chart. Logto is © its authors, licensed under MPL-2.0.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install logto upstreamyard/logto \
  --set database.url='postgres://logto:password@your-postgres:5432/logto' \
  --set endpoint=https://auth.example.com \
  --set adminConsole.endpoint=https://admin.auth.example.com
```

Or from the OCI registry:

```bash
helm install logto oci://ghcr.io/upstreamyard/charts/logto \
  --set database.url='postgres://logto:password@your-postgres:5432/logto'
```

Then create the admin account right away (see "Admin Console" below):

```bash
kubectl port-forward svc/logto 3002:3002   # http://localhost:3002
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install logto upstreamyard/logto --verify --keyring upstreamyard.gpg --set database.url='...'
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **PostgreSQL 14 or newer** (required; tested with 17). This chart does not deploy a database.
- **The database user must be allowed to create roles** (`CREATEROLE` or superuser). Logto creates PostgreSQL roles for its tenants when it sets up the database; without the permission, setup fails with `permission denied to create role`. Logto's docs don't mention this.
- **Redis** is optional: a shared cache that reduces database reads.

## What the chart does

- **Database setup and upgrades:** before every install and upgrade, a Job sets up an empty database (`npm run cli db seed -- --swe`, skipped when it's already set up) and deploys the database alterations of the new Logto version (`npm run alteration deploy latest`). Logto refuses to start until they are deployed.
- **Non-root:** Logto's image runs as root by default; the chart runs it as UID 10001. Logto writes alteration scripts into a folder that only root's group may write to, so the chart mounts an empty volume there.
- **Two endpoints:** Logto serves your apps on port `3001` (`endpoint`) and the Admin Console on port `3002` (`adminConsole.endpoint`). Each has its own Ingress (`ingress`, `adminIngress`) and should get its own host name. `trustProxyHeader` is on, so Logto uses the `X-Forwarded-*` headers of your Ingress.
- **Probes:** `/api/status` for startup, liveness and readiness.
- **Several replicas:** all pods share the database; Redis is optional.
- **Connectors:** the official connectors (social sign-in, email, SMS) are part of the image, so nothing is downloaded at startup.
- **Security:** runs as non-root UID 10001, drops all capabilities, and doesn't mount a ServiceAccount token.

## Admin Console

On a new installation, **the first person who opens the Admin Console creates the admin account**. Create it right away through `kubectl port-forward`, before you enable `adminIngress`, or restrict the admin Ingress (e.g. by IP or VPN). To run Logto without the Admin Console, set `adminConsole.enabled=false`.

## Configuration

Logto is configured through environment variables; the chart sets the essential ones from its values. Everything else goes into `extraEnv` or `extraEnvFrom`, for example:

```yaml
extraEnv:
  - name: CASE_SENSITIVE_USERNAME
    value: "false"
  - name: DATABASE_STATEMENT_TIMEOUT
    value: DISABLE_TIMEOUT          # when connecting through PgBouncer or RDS Proxy
```

All variables are listed in Logto's [configuration reference](https://docs.logto.io/concepts/core-service/configuration). To use Logto's [Secret Vault](https://docs.logto.io/secret-vault), set `secretVault.kek` (or `secretVault.existingSecret`) to a base64-encoded 32-byte key, e.g. from `openssl rand -base64 32`.

## Production example

```yaml
# values-prod.yaml
replicaCount: 2
database:
  existingSecret: logto-db          # key: database-url
redis:
  existingSecret: logto-redis       # key: redis-url
secretVault:
  existingSecret: logto-kek         # key: secret-vault-kek
endpoint: https://auth.example.com
adminConsole:
  endpoint: https://admin.auth.example.com
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: auth.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: auth-tls
      hosts: [auth.example.com]
adminIngress:
  enabled: true
  className: nginx
  annotations: {}                   # restrict access, e.g. an IP allow-list
  hosts:
    - host: admin.auth.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: admin-auth-tls
      hosts: [admin.auth.example.com]
```

## Known issue: restarts when the database drops connections

When PostgreSQL closes Logto's connections (a database restart or failover), Logto 1.44.0 exits with an unhandled database error (`terminating connection due to administrator command`), so Kubernetes restarts the pod. It comes back as soon as the database is reachable; expect a few restarts and a short outage during database maintenance.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| adminConsole.enabled | bool | `true` | Serve the Admin Console on port 3002. If false, the chart sets `ADMIN_DISABLE_LOCALHOST=1` and doesn't expose the admin port. |
| adminConsole.endpoint | string | `""` | Public URL of the Admin Console (`ADMIN_ENDPOINT`), e.g. `https://admin.auth.example.com`. Empty means `http://localhost:3002`. |
| adminIngress.annotations | object | `{}` | Ingress annotations. |
| adminIngress.className | string | `""` | Ingress class name. |
| adminIngress.enabled | bool | `false` | Create an Ingress for the Admin Console (port 3002). Its host should match `adminConsole.endpoint`. The first visitor of a new installation creates the admin account, so restrict access (e.g. by IP) until that is done. |
| adminIngress.hosts | list | `[{"host":"admin.auth.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| adminIngress.tls | list | `[]` | Ingress TLS configuration. |
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the connection string (recommended for production). |
| database.existingSecretKey | string | `"database-url"` | Key in `existingSecret` that holds the connection string. |
| database.url | string | `""` | Connection string `postgres://user:password@host:5432/logto`. URL-encode special characters in the password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| endpoint | string | `""` | Public URL of Logto (`ENDPOINT`), e.g. `https://auth.example.com`. It becomes the OIDC issuer, so set it before your apps use Logto. Empty means `http://localhost:3001`. |
| extraEnv | list | `[]` | Extra environment variables for Logto, e.g. `CASE_SENSITIVE_USERNAME`, `DATABASE_STATEMENT_TIMEOUT`, proxy settings. See https://docs.logto.io/concepts/core-service/configuration |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the Logto container. |
| extraVolumes | list | `[]` | Extra volumes for the pod, e.g. TLS certificates for `HTTPS_CERT_PATH`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"svhd/logto"` | Image repository. The official Logto image. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the Logto core service (port 3001). Its host should match `endpoint`. |
| ingress.hosts | list | `[{"host":"auth.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| livenessProbe | object | `{"httpGet":{"path":"/api/status","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on `/api/status`. |
| migrations.activeDeadlineSeconds | int | `600` | Maximum runtime of the Job in seconds. |
| migrations.backoffLimit | int | `3` | Retries of the Job before the install/upgrade fails. |
| migrations.enabled | bool | `true` |  |
| migrations.resources | object | `{}` | Resources for the Job. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Runs Logto as non-root UID 10001 (the image itself defaults to root). |
| readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/api/status","port":"http"},"periodSeconds":5,"timeoutSeconds":5}` | Readiness probe on `/api/status`. |
| redis.existingSecret | string | `""` | Name of an existing Secret that holds the Redis URL. |
| redis.existingSecretKey | string | `"redis-url"` | Key in `existingSecret` that holds the Redis URL. |
| redis.url | string | `""` | Redis URL, e.g. `redis://redis:6379`. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| replicaCount | int | `1` | Number of Logto pods. Logto keeps no state in the pod, so several replicas share the PostgreSQL database. Redis (`redis.url`) is optional and only adds a shared cache. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources for the Logto container. |
| secretVault.existingSecret | string | `""` | Name of an existing Secret that holds the key encryption key. |
| secretVault.existingSecretKey | string | `"secret-vault-kek"` | Key in `existingSecret` that holds the key encryption key. |
| secretVault.kek | string | `""` | Key encryption key for Logto's Secret Vault (`SECRET_VAULT_KEK`): a base64-encoded 32-byte key, e.g. `openssl rand -base64 32`. Optional; the Secret Vault doesn't work without it. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}` | Container security context. |
| service.adminPort | int | `3002` | Port of the Admin Console (only when `adminConsole.enabled`). |
| service.port | int | `3001` | Port of the Logto core service (sign-in pages, OIDC, Management API). |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Logto does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":30,"httpGet":{"path":"/api/status","port":"http"},"periodSeconds":2}` | Startup probe on `/api/status` (answers 204 as soon as the server is up). |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after SIGTERM. Logto stops within a second. |
| tolerations | list | `[]` | Tolerations. |
| trustProxyHeader | bool | `true` | Trust `X-Forwarded-*` headers (`TRUST_PROXY_HEADER`). Needed behind an Ingress or load balancer that terminates TLS. |
