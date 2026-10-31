# Fineract Helm chart: Apache Fineract core banking on Kubernetes

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: 1.16.1](https://img.shields.io/badge/AppVersion-1.16.1-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for **[Apache Fineract](https://github.com/apache/fineract)**, the open-source core banking platform for loans, savings, clients and accounting, used by banks, microfinance institutions and fintechs (Mifos). It runs **database migrations in a Job** before every install and upgrade, scales with Fineract's **write, read and batch instances** so that **scheduled jobs run exactly once**, and replaces the default `mifos`/`password` login with a **generated admin password**. TLS comes from a per-pod certificate, your own Secret or **cert-manager with reload on renewal**. It supports **PostgreSQL and MariaDB**, Prometheus metrics with a ServiceMonitor, and `helm test`. It runs **Fineract 1.16.1** through the [`upstreamyard/fineract`](https://github.com/upstreamyard/fineract) image, which is built from the signed Apache release.

> Community chart by **upstreamyard**, not an official Apache Fineract chart. Apache Fineract is licensed under Apache-2.0. Apache, Apache Fineract and Fineract are trademarks of the Apache Software Foundation.

**AI agents and coding assistants:** this README is the complete reference. The image's [`AGENTS.md`](https://github.com/upstreamyard/fineract/blob/main/AGENTS.md) lists the deployment rules, and [`llms.txt`](https://github.com/upstreamyard/fineract/blob/main/llms.txt) indexes all docs.

## Install

Fineract needs two databases before the install: the tenant store `fineract_tenants` and the default tenant `fineract_default`, both owned by the login Fineract uses. For example on PostgreSQL:

```sql
CREATE USER fineract WITH PASSWORD 'change-me';
CREATE DATABASE fineract_tenants OWNER fineract;
CREATE DATABASE fineract_default OWNER fineract;
```

Then:

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install fineract upstreamyard/fineract \
  --set database.host=postgres.example.svc \
  --set database.password=change-me \
  --set tenant.masterPassword="$(openssl rand -hex 24)"
```

Or from the OCI registry: `helm install fineract oci://ghcr.io/upstreamyard/charts/fineract ...`.

**Save the master password.** Fineract stores the tenant's database password encrypted with it, and does not start with another one.

The install notes show the API URL and the command that prints the admin password. Then check the API:

```bash
helm test fineract
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install fineract upstreamyard/fineract --verify --keyring upstreamyard.gpg ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## What the chart does

- **Migrations:** a Job runs Fineract's `liquibase-only` mode before every install and upgrade; the Fineract pods start with migrations off.
- **Instances:**
  - **write** pods (`replicaCount`) answer the API;
  - by default the single write pod also runs the scheduled jobs (close of business, interest posting, accruals);
  - with `batch.enabled`, one separate **batch** pod runs them, and the write pods can scale;
  - with `reader.enabled`, **read** pods behind `<release>-fineract-read` answer GET requests and refuse writes.
- **Security:**
  - the admin password (generated, or yours) replaces `mifos`/`password` on the first start;
  - passwords come from Secrets;
  - non-root (UID 10001), read-only root filesystem, all capabilities dropped, no ServiceAccount token. Tested under Pod Security `restricted`.
- **TLS:** HTTPS on 8443 with a certificate generated per pod (default), your own `kubernetes.io/tls` Secret, or a cert-manager Certificate. Secret certificates are reloaded when they are renewed, without a restart. Or plain HTTP on 8080 behind your ingress.
- **Documents:** uploaded documents and images go to a PersistentVolumeClaim, kept on `helm uninstall`.
- **Probes:** startup, liveness and readiness on Fineract's health endpoints. A PodDisruptionBudget covers scaled write and read pods.
- **Metrics:** `metrics.serviceMonitor.enabled` scrapes `/fineract-provider/actuator/prometheus` on every pod.

## Why this chart

Compared with the other Fineract charts on Artifact Hub (checked 2026-10-31):

| | Other Fineract charts | This chart |
|---|---|---|
| Fineract version | 1.12.1 or older; one has no version | 1.16.1, updated with every Apache release |
| Image | `apache/fineract` (no version tags after 1.12.1) | [`upstreamyard/fineract`](https://github.com/upstreamyard/fineract), built from the signed Apache release |
| Admin login | `mifos` / `password` | generated password, set on the first start |
| Databases | MySQL bundled in the chart | your PostgreSQL or MariaDB; nothing bundled |
| Migrations | on server start | Job before every install and upgrade |
| Scaling | one server | write, read and batch pods; jobs run once |
| TLS | none, or at the ingress | per-pod certificate, Secret or cert-manager with reload |
| Upgrade 1.15.0 → 1.16.1 (tested) | – | rolling, 0 of 87 writes failed |

## Deployment modes

### One pod (default)

One pod answers the API and runs the scheduled jobs. It is replaced with `Recreate`, because two schedulers must never overlap, so a restart or upgrade takes the API offline for about 20 seconds (measured: 21 failed requests at one per second when the pod was deleted).

```yaml
database:
  host: postgres.example.svc
  existingSecret: fineract-db
tenant:
  existingSecret: fineract-keys
```

### Scaled: write, batch and read pods

Several write pods need a separate batch pod, so that scheduled jobs run exactly once, and documents on shared storage (`ReadWriteMany`) or in S3. Upgrades and restarts then roll without downtime.

```yaml
database:
  host: postgres.example.svc
  existingSecret: fineract-db
tenant:
  existingSecret: fineract-keys
replicaCount: 2
batch:
  enabled: true
reader:
  enabled: true
  replicaCount: 2
persistence:
  accessModes: [ReadWriteMany]
  storageClass: my-rwx-class
```

Tested in kind with two write pods, one batch and one read pod:

- **Rolling upgrade from Fineract 1.15.0 to 1.16.1** (migration Job included) while a client created one Fineract client per second: 0 of 87 writes failed.
- **A deleted write pod:** 0 of 71 writes failed.
- **Shared documents:** a document uploaded through a write pod was downloaded through the read Service.
- **Scheduled jobs:** only the batch pod starts the scheduler. The others log `Batch job scheduling is disabled since this instance is not a batch manager`.

The read Service only answers GET requests; Fineract returns `405` for anything else. Point reporting and other read-heavy clients at `<release>-fineract-read`, everything else at the write Service.

### MariaDB

```yaml
database:
  type: mariadb
  host: mariadb.example.svc
  existingSecret: fineract-db
tenant:
  existingSecret: fineract-keys
```

Start MariaDB with `--character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --innodb-snapshot-isolation=OFF` (Fineract's own MariaDB settings). Tested with MariaDB 11.8.

## Database sizing

Each Fineract pod has two connection pools: the tenant store (up to 10 connections) and the tenant database (up to 40, a default Fineract stores when it creates the tenant). Idle, a pod keeps 8 connections open (measured); its pools allow up to 50. Plan `max_connections` for all pods plus the migration Job, or cap the tenant pool:

```yaml
extraEnv:
  - name: FINERACT_CONFIG_MAX_POOL_SIZE
    value: "15"
```

Fineract then logs `Overriding tenant datasource maximum pool size configuration to 15` (tested). In our tests, about 12 pods on one PostgreSQL with its default of 100 connections made new pods fail with `remaining connection slots are reserved for roles with the SUPERUSER attribute`.

## TLS

| `tls.mode` | Port | Certificate |
|---|---|---|
| `generated` (default) | 8443 HTTPS | self-signed, generated by each pod at start |
| `secret` | 8443 HTTPS | `tls.secretName`, or cert-manager with `tls.certManager.enabled`; reloaded when renewed |
| `disabled` | 8080 HTTP | none: TLS ends at your ingress or load balancer |

With cert-manager:

```yaml
tls:
  mode: secret
  certManager:
    enabled: true
    issuerRef:
      name: internal-ca
      kind: ClusterIssuer
    dnsNames: [fineract.example.com]
```

The Certificate covers the chart's Service names. Tested with a self-signed ClusterIssuer: after cert-manager issued a new certificate, the running pod served it 82 seconds later, without a restart. Most of that time is the kubelet updating the mounted Secret.

With an Ingress and `tls.mode` `generated` or `secret`, configure your ingress controller to connect to the backend over HTTPS. Or use `tls.mode: disabled` and terminate TLS at the ingress.

## Connecting clients

| Use | URL |
|---|---|
| API (writes and reads) | `https://<release>-fineract.<namespace>.svc:8443/fineract-provider/api/v1` |
| Read-only API | `https://<release>-fineract-read.<namespace>.svc:8443/fineract-provider/api/v1` |
| Jobs API (with `batch.enabled`) | `https://<release>-fineract-batch.<namespace>.svc:8443/fineract-provider/api/v1/jobs` |
| Swagger UI | `https://<release>-fineract.<namespace>.svc:8443/fineract-provider/swagger-ui/index.html` |

With `tls.mode: disabled` use `http://` and port 8080. Every request needs the header `Fineract-Platform-TenantId: default` and HTTP basic auth, e.g. user `mifos` with the admin password:

```bash
kubectl get secret fineract -o jsonpath='{.data.admin-password}' | base64 -d
```

Fineract is the API server. For a web UI, run the separate [Mifos X web app](https://github.com/openMF/web-app) against it.

## Upgrading

`helm upgrade` first runs the migration Job with the new Fineract version while the old pods keep serving, then replaces the pods. Pin `image.tag` to control when migrations happen, and back up the database first. Going back to an older Fineract version after its migrations ran is not supported by Fineract.

## Operations

- **Settings fixed at the first install:** Fineract stores the default tenant's database host, port, name, login, password, connection parameters and time zone in the tenant store. Later changes to `database.*` and `tenant.timezone` only affect the tenant store connection; the tenant keeps its stored values (tested).
- **Changing the database password:** change it in the database and in your Secret. Then store the new password, encrypted with the master password, in the tenant store:

  ```bash
  kubectl exec deploy/fineract -- java -cp /app/fineract-provider.jar \
    -Dloader.main=org.apache.fineract.infrastructure.core.service.database.DatabasePasswordEncryptor \
    org.springframework.boot.loader.launch.PropertiesLauncher '<master password>' '<new password>'
  # prints "The encrypted password: ..."; then, on the tenant store database:
  # UPDATE tenant_server_connections SET schema_password = '<encrypted password>' WHERE id = 1;
  ```

  Restart the pods afterwards (tested with PostgreSQL 18).
- **Uninstall:** `helm uninstall` keeps the documents PVC and the chart's Secret with the admin password (`helm.sh/resource-policy: keep`). A new install with the same release name takes both over (tested). Delete them by hand to remove everything.
- **Argo CD and `helm template`:** they can't read the existing Secret, so set `admin.password` or `admin.existingSecret` instead of relying on the generated password.

## Production example

```yaml
# values-prod.yaml
database:
  host: fineract-db-rw.databases.svc
  existingSecret: fineract-db
  existingSecretKey: password
  parameters: sslmode=require
tenant:
  timezone: Africa/Nairobi
  existingSecret: fineract-keys
  existingSecretKey: master-password
admin:
  existingSecret: fineract-keys
  existingSecretKey: admin-password
replicaCount: 2
batch:
  enabled: true
reader:
  enabled: true
  replicaCount: 2
persistence:
  accessModes: [ReadWriteMany]
  storageClass: my-rwx-class
  size: 50Gi
tls:
  mode: secret
  certManager:
    enabled: true
    issuerRef:
      name: internal-ca
      kind: ClusterIssuer
resources:
  requests:
    cpu: "1"
    memory: 3Gi
  limits:
    memory: 3Gi
metrics:
  serviceMonitor:
    enabled: true
```

## Your own configuration

- **Other Fineract settings:** `extraEnv` with Fineract's `FINERACT_*` variables, e.g. S3 storage for documents (`FINERACT_CONTENT_S3_*`) or external events. The [image README](https://github.com/upstreamyard/fineract#configuration) lists the important ones; Fineract's [configuration reference](https://fineract.apache.org/docs/stable/#_appendix_a_properties_and_environment_variables) has all.
- **JDBC drivers and plugins:** jars mounted at `/app/plugins` through `extraVolumes` and `extraVolumeMounts` are loaded.
- **Memory:** the heap is 60% of the memory limit. Use at least 2 GiB.

## FAQ

**Is there an official Apache Fineract Helm chart?** No. Fineract's documentation has a "Helm Charts" page that says "TBD". This chart is maintained by upstreamyard together with the image.

**What is the default Fineract login?** User `mifos`, password `password`. This chart replaces the password on the first start with `admin.password` or a generated one; the install notes show how to read it.

**How do I run Fineract highly available on Kubernetes?** `replicaCount: 2` or more with `batch.enabled: true` and `ReadWriteMany` storage (or S3); see [Scaled](#scaled-write-batch-and-read-pods).

**Why does Fineract fail with `Invalid master password`?** The master password differs from the one used at the first install. Set the original value again.

**Why do I get `405 Invalid instance type called in api request`?** You sent a write request to a read pod, or a non-job request to the batch pod. Use the write Service.

**Why does a new pod fail with `remaining connection slots are reserved`?** The database ran out of connections; see [Database sizing](#database-sizing).

**How do I monitor Fineract with Prometheus?** `metrics.serviceMonitor.enabled=true`, or scrape `/fineract-provider/actuator/prometheus` on port 8443 (HTTPS) or 8080.

**Does it support MySQL?** Not in this chart. Fineract supports MySQL, but the driver isn't included in the image for licence reasons; use PostgreSQL or MariaDB.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admin.existingSecret | string | `""` | Existing Secret with the admin password. |
| admin.existingSecretKey | string | `"admin-password"` | Key of the admin password in `existingSecret`. |
| admin.password | string | `""` | Password that replaces `mifos`/`password` on the first start. Empty: generated and kept in the chart's Secret (key `admin-password`). 12–50 characters with upper and lower case, a digit and a special character, no spaces, no character twice in a row. |
| affinity | object | `{}` | Affinity. Empty: write and read pods prefer different nodes. |
| batch.enabled | bool | `false` | Run scheduled jobs (close of business, interest posting, …) in their own pod. Always exactly 1 pod, so jobs run once. |
| batch.resources | object | `{}` | Resources of the batch pod. Empty: `resources`. |
| database.defaultTenantDatabase | string | `"fineract_default"` | Database of the default tenant. Must exist before the install. |
| database.existingSecret | string | `""` | Existing Secret with the database password. |
| database.existingSecretKey | string | `"password"` | Key of the password in `existingSecret`. |
| database.host | string | `""` | Database host (required), e.g. `fineract-postgres.db.svc`. |
| database.parameters | string | `""` | JDBC connection parameters for both databases, e.g. `sslmode=require` (PostgreSQL) or `sslMode=verify-full` (MariaDB). |
| database.password | string | `""` | Password. Use `existingSecret` in production. |
| database.port | string | `""` | Port. Empty: 5432 for PostgreSQL, 3306 for MariaDB. |
| database.tenantsDatabase | string | `"fineract_tenants"` | Tenant store database. Must exist before the install. |
| database.type | string | `"postgresql"` | `postgresql` or `mariadb` (MariaDB needs utf8mb4 and `--innodb-snapshot-isolation=OFF`, see the README). |
| database.username | string | `"fineract"` | Login for both databases. It must be able to create tables in them. |
| extraEnv | list | `[]` | Extra environment variables for all Fineract containers, e.g. other `FINERACT_*` settings. |
| extraEnvFrom | list | `[]` | Extra `envFrom` sources for all Fineract containers. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for all Fineract containers. |
| extraVolumes | list | `[]` | Extra volumes, e.g. JDBC drivers or plugins for `/app/plugins`. |
| fullnameOverride | string | `""` | Override the full name of the release's resources. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"upstreamyard/fineract"` | Fineract image. Built from the signed Apache release; see https://github.com/upstreamyard/fineract |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion (the Fineract version). |
| imagePullSecrets | list | `[]` | Pull secrets for private registries, e.g. `[{name: my-registry}]`. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class. |
| ingress.enabled | bool | `false` | Ingress for the write Service. With `tls.mode` other than `disabled`, tell your controller the backend speaks HTTPS (README). |
| ingress.hosts | list | `[]` | Hosts and paths, e.g. `[{host: fineract.example.com, paths: [{path: /fineract-provider, pathType: Prefix}]}]`. |
| ingress.tls | list | `[]` | TLS settings of the Ingress. |
| javaOpts | string | `""` | Extra Java options (`JAVA_OPTS`), added after the image's own. |
| logging.json | bool | `false` | One JSON object per log line. |
| logging.level | string | `"INFO"` | Log level of `org.apache.fineract`. |
| metrics.serviceMonitor.enabled | bool | `false` | ServiceMonitor for the Prometheus Operator (all Fineract pods, `/fineract-provider/actuator/prometheus`). |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the label your Prometheus selects. |
| migrations.activeDeadlineSeconds | int | `3600` | Seconds before the migration Job is stopped. |
| migrations.backoffLimit | int | `1` | Retries of the migration Job. |
| migrations.enabled | bool | `true` | Run database migrations in a Job before every install and upgrade (Fineract's `liquibase-only` mode). If false, the write pods migrate on start. |
| migrations.resources | object | `{}` | Resources of the migration Job. Empty: `resources`. |
| nameOverride | string | `""` | Override the chart name. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. Several write pods or read pods need `[ReadWriteMany]` (set it to match `existingClaim` too). |
| persistence.enabled | bool | `true` | Volume for uploaded documents and images (`/var/lib/fineract`). Without it they are lost when a pod restarts. The PVC is kept on `helm uninstall`. |
| persistence.existingClaim | string | `""` | Use an existing PVC. |
| persistence.size | string | `"10Gi"` | Volume size. |
| persistence.storageClass | string | `""` | Storage class. Empty: the cluster default. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | PodDisruptionBudget (`maxUnavailable: 1`) for the write and read pods when they have more than 1 replica. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| probes.livenessFailureThreshold | int | `6` | Liveness probe failures before a restart (10 s apart). |
| probes.readinessFailureThreshold | int | `3` | Readiness probe failures before the pod leaves the Service (10 s apart). |
| probes.startupFailureThreshold | int | `60` | Startup budget in 10 s steps. A first start without the migration Job creates all tables (minutes). |
| reader.enabled | bool | `false` | Read-only pods behind the `<fullname>-read` Service: they answer GET requests and refuse writes. Need shared document storage. |
| reader.replicaCount | int | `2` | Number of read pods. |
| reader.resources | object | `{}` | Resources of the read pods. Empty: `resources`. |
| replicaCount | int | `1` | Write pods (or all-in-one pods while `batch.enabled` is false). More than 1 requires `batch.enabled` and shared document storage. |
| resources | object | `{"limits":{"memory":"2Gi"},"requests":{"cpu":"500m","memory":"2Gi"}}` | Resources of every Fineract pod. Right after the start Fineract uses about 1.5 GiB; the heap is 60% of the limit. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Annotations for the Services. |
| service.type | string | `"ClusterIP"` | Service type of the write Service (and the read and batch Services). |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: the full name. |
| tenant.existingSecret | string | `""` | Existing Secret with the master password. |
| tenant.existingSecretKey | string | `"master-password"` | Key of the master password in `existingSecret`. |
| tenant.identifier | string | `"default"` | Identifier of the default tenant; clients send it in the `Fineract-Platform-TenantId` header. |
| tenant.masterPassword | string | `""` | Master password that encrypts the tenant's database password (required). Set it once and never change it. |
| tenant.timezone | string | `"UTC"` | Time zone of the default tenant, stored on the first install (Fineract's own default is Asia/Kolkata). |
| terminationGracePeriodSeconds | int | `60` | Seconds a pod has to stop. Fineract waits up to 30 s for running requests. |
| tests.enabled | bool | `true` | Include the `helm test` pod (readiness and an authenticated API call). |
| tls.certManager.dnsNames | list | `[]` | Extra DNS names, e.g. your public host name. The Service names are always included. |
| tls.certManager.duration | string | `""` | Certificate lifetime, e.g. `2160h`. Empty: the issuer's default. |
| tls.certManager.enabled | bool | `false` | Create a cert-manager Certificate for the chart's Services (needs `mode: secret`). |
| tls.certManager.issuerRef.group | string | `"cert-manager.io"` | Issuer API group. |
| tls.certManager.issuerRef.kind | string | `"Issuer"` | `Issuer` or `ClusterIssuer`. |
| tls.certManager.issuerRef.name | string | `""` | Issuer or ClusterIssuer name. |
| tls.certManager.renewBefore | string | `""` | Renew this long before expiry, e.g. `360h`. Empty: cert-manager's default. |
| tls.mode | string | `"generated"` | `generated`: HTTPS on 8443 with a self-signed certificate per pod. `secret`: HTTPS with the certificate in `tls.secretName` or from cert-manager, reloaded on renewal. `disabled`: HTTP on 8080, TLS ends at your ingress or load balancer. |
| tls.secretName | string | `""` | With `mode: secret`: a `kubernetes.io/tls` Secret (keys `tls.crt`, `tls.key`). Empty with `certManager.enabled`: `<fullname>-tls`. |
| tolerations | list | `[]` | Tolerations. |
