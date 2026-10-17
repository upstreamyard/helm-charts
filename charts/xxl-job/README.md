# XXL-JOB Helm chart

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![AppVersion: 3.5.0](https://img.shields.io/badge/AppVersion-3.5.0-informational?style=flat-square)

Helm chart for the admin (scheduling center) of [XXL-JOB](https://github.com/xuxueli/xxl-job), the distributed job scheduler for Java services: a web UI and API that trigger jobs on your executors by cron, with retries, sharding, failover, alerts and logs. It uses XXL-JOB's official image [`xuxueli/xxl-job-admin`](https://hub.docker.com/r/xuxueli/xxl-job-admin).

> Community chart by **upstreamyard**, not an official XXL-JOB chart. XXL-JOB is © its authors, licensed under GPL-3.0.

## Install

Create an empty MySQL database first (see [Requirements](#requirements)), then:

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install xxl-job upstreamyard/xxl-job \
  --set database.host=your-mysql \
  --set database.username=xxljob \
  --set database.password='your-password'
```

Or from the OCI registry:

```bash
helm install xxl-job oci://ghcr.io/upstreamyard/charts/xxl-job \
  --set database.host=your-mysql --set database.username=xxljob --set database.password='your-password'
```

Then open the web UI and sign in as `admin` with the generated password:

```bash
kubectl get secret xxl-job -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl port-forward svc/xxl-job 8080:8080   # http://localhost:8080
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install xxl-job upstreamyard/xxl-job --verify --keyring upstreamyard.gpg --set database.host=...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **MySQL** (required; tested with 8.4). This chart does not deploy a database.
- **An existing database** with the `utf8mb4` character set, and a user with `CREATE`, `SELECT`, `INSERT`, `UPDATE` and `DELETE` on it:

  ```sql
  CREATE DATABASE xxl_job DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER 'xxljob'@'%' IDENTIFIED BY 'your-password';
  GRANT CREATE, SELECT, INSERT, UPDATE, DELETE ON xxl_job.* TO 'xxljob'@'%';
  ```

- **amd64 nodes.** The official image is built for amd64 only, so the chart sets `nodeSelector: {kubernetes.io/arch: amd64}`.

## What the chart does

- **Database setup:** before every install and upgrade, a Job (with the `mysql:8.4` client image) creates XXL-JOB's tables if they are missing. On a database without users, it also creates the first admin user. XXL-JOB itself doesn't create its tables.
- **No default credentials:** XXL-JOB's own SQL script creates `admin` / `123456` and two sample executor groups with the access token `default_token`. The chart doesn't. It creates `admin` with a random password (or `admin.password` / `admin.existingSecret`) and no sample data, so every executor group gets its own token in the web UI.
- **Several replicas:** all pods share MySQL. XXL-JOB takes a database lock when it schedules, so each job is triggered once, and sign-in sessions are stored in the database, so any pod can serve any request.
- **Time zone and language:** the image defaults to China time (`PRC`) and a Chinese UI. The chart sets `timezone: UTC` (also used for the JDBC connection) and `language: en`. Cron expressions run in `timezone`.
- **Clean shutdown:** the image starts Java through a shell that doesn't pass on `SIGTERM`, so Kubernetes kills the admin only after the grace period (30 s), in the middle of scheduling. The chart starts the same command with `exec`, so the admin stops cleanly within about 5 seconds.
- **Probes:** Spring Boot's `actuator/health/liveness` (startup, liveness) and `actuator/health/readiness`. Readiness doesn't depend on MySQL, so a database outage doesn't take every pod out of the Service at once.
- **Security:** runs as non-root UID 10001 (the image defaults to root) with a read-only root filesystem, drops all capabilities and doesn't mount a ServiceAccount token. `/tmp` and the log folder are empty volumes.

## Connecting executors

Executors are your own services that embed `xxl-job-core` ([XXL-JOB docs](https://github.com/xuxueli/xxl-job/blob/master/doc/XXL-JOB-English-Documentation.md)). This chart doesn't deploy them. In the web UI, create an executor group with its `AppName` and access token (Executor Manager), then configure the executor:

```properties
xxl.job.admin.addresses=http://xxl-job.<namespace>.svc:8080/
xxl.job.executor.appname=<the group's AppName>
xxl.job.executor.accessToken=<the group's access token>
```

Executors register their own address with the admin, and the admin then calls them directly. In Kubernetes, that is the pod IP and the executor port (9999 by default), so allow traffic from the admin pods to your executor pods if you use NetworkPolicies. The admin picks up a newly registered executor within about 30 seconds.

## Configuration

The chart sets the database, time zone, language and context path from its values. All other XXL-JOB and Spring properties work as environment variables in `extraEnv` (dots become underscores, upper case), for example:

```yaml
extraEnv:
  - name: XXL_JOB_LOGRETENTIONDAYS     # xxl.job.logretentiondays
    value: "14"
  - name: SPRING_MAIL_HOST             # alert e-mails
    value: smtp.example.com
  - name: SPRING_MAIL_PORT
    value: "587"
  - name: SPRING_MAIL_USERNAME
    value: xxl-job@example.com
  - name: SPRING_MAIL_FROM
    value: xxl-job@example.com
extraEnvFrom:
  - secretRef:
      name: xxl-job-mail               # key: SPRING_MAIL_PASSWORD
```

All properties are listed in XXL-JOB's [`application.properties`](https://github.com/xuxueli/xxl-job/blob/master/xxl-job-admin/src/main/resources/application.properties). To keep them in a file instead, mount a ConfigMap with `extraVolumes` / `extraVolumeMounts` and point `SPRING_CONFIG_ADDITIONAL_LOCATION` at it:

```yaml
extraEnv:
  - name: SPRING_CONFIG_ADDITIONAL_LOCATION
    value: file:/config/
extraVolumes:
  - name: config
    configMap:
      name: xxl-job-config             # key: application.properties
extraVolumeMounts:
  - name: config
    mountPath: /config
    readOnly: true
```

## Production example

```yaml
# values-prod.yaml
replicaCount: 2
database:
  host: mysql.example.internal
  username: xxljob
  existingSecret: xxl-job-db          # key: db-password
  extraParams: sslMode=REQUIRED
admin:
  existingSecret: xxl-job-admin       # key: admin-password
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: xxl-job.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: xxl-job-tls
      hosts: [xxl-job.example.com]
```

## Upgrades

XXL-JOB has no database migrations. When a release changes the schema, its release notes contain the `ALTER TABLE` statements (in the Chinese documentation, e.g. for 3.5.0). The chart's setup Job creates missing tables, but it **never alters existing ones**. Before upgrading to a release with schema changes, run that release's statements on your database. The chart's `appVersion` changes only after we have checked the release.

## Known issues

- **Error details on failed sign-ins:** when the database is unreachable or a table is missing, XXL-JOB 3.5.0 answers the sign-in request with the full exception, including SQL. Don't expose the web UI to the internet; restrict the Ingress (e.g. by IP or VPN).
- **One session per user:** signing in ends the user's session in other browsers. Give each person their own user (User Manager in the web UI).

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admin.existingSecret | string | `""` | Name of an existing Secret that holds the admin password. |
| admin.existingSecretKey | string | `"admin-password"` | Key in `existingSecret` that holds the admin password. |
| admin.password | string | `""` | Password of the first admin. Empty means a random password, stored in the chart's Secret (see NOTES after install). Ignored when `existingSecret` is set. |
| admin.username | string | `"admin"` | User name of the first admin. |
| affinity | object | `{}` | Affinity. |
| contextPath | string | `"/"` | Context path of the web UI and API (`server.servlet.context-path`), e.g. `/xxl-job-admin`. Executors use it in `xxl.job.admin.addresses`. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the database password (recommended for production). |
| database.existingSecretKey | string | `"db-password"` | Key in `existingSecret` that holds the database password. |
| database.extraParams | string | `""` | Extra JDBC URL parameters, appended to `useUnicode=true&characterEncoding=UTF-8&serverTimezone=<timezone>`, e.g. `sslMode=REQUIRED`. |
| database.host | string | `""` | MySQL host name. |
| database.name | string | `"xxl_job"` | Database name. |
| database.password | string | `""` | Database password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| database.port | int | `3306` | MySQL port. |
| database.username | string | `""` | Database user. Needs CREATE, SELECT, INSERT, UPDATE and DELETE on the database. |
| extraEnv | list | `[]` | Extra environment variables for the admin, e.g. Spring properties as `XXL_JOB_LOGRETENTIONDAYS` or `SPRING_MAIL_HOST`. See the properties in https://github.com/xuxueli/xxl-job/blob/master/xxl-job-admin/src/main/resources/application.properties |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps, e.g. `SPRING_MAIL_PASSWORD`. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the admin container. |
| extraVolumes | list | `[]` | Extra volumes for the pod, e.g. a ConfigMap with extra Spring properties, loaded with `SPRING_CONFIG_ADDITIONAL_LOCATION` in `extraEnv`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"xuxueli/xxl-job-admin"` | Image repository. The official XXL-JOB admin image (amd64 only). |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the web UI. Executors in the cluster should use the Service instead. |
| ingress.hosts | list | `[{"host":"xxl-job.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| javaOpts | string | `"-XX:MaxRAMPercentage=75.0"` | JVM options (`JAVA_OPTS`). |
| language | string | `"en"` | Language of the web UI and alert texts (`xxl.job.i18n`): `en`, `zh_CN` or `zh_TC`. |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe timing on `<contextPath>actuator/health/liveness`. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{"kubernetes.io/arch":"amd64"}` | Node selector. The official image is built for amd64 only. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. Runs the admin as non-root UID 10001 (the image itself defaults to root). |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":5,"timeoutSeconds":5}` | Readiness probe timing on `<contextPath>actuator/health/readiness`. |
| replicaCount | int | `1` | Number of admin pods. All replicas share the MySQL database; a database lock ensures each job is triggered only once. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"512Mi"}}` | Resources for the admin container. |
| schemaSetup.activeDeadlineSeconds | int | `300` | Maximum runtime of the Job in seconds. |
| schemaSetup.backoffLimit | int | `3` | Retries of the Job before the install/upgrade fails. |
| schemaSetup.enabled | bool | `true` | Create XXL-JOB's tables (if missing) and the first admin user (if the database has no users) in a Job before every install and upgrade (Helm hook). Existing tables and data are never changed. If false, you load XXL-JOB's `tables_xxl_job.sql` yourself. |
| schemaSetup.image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| schemaSetup.image.repository | string | `"mysql"` | Image with the `mysql` client for the setup Job. |
| schemaSetup.image.tag | string | `"8.4"` | Image tag. |
| schemaSetup.resources | object | `{}` | Resources for the Job. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The root filesystem is read-only; the chart mounts empty volumes for `/tmp` and the log folder. |
| service.port | int | `8080` | Service port of the web UI and the API that executors call. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. XXL-JOB does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":40,"periodSeconds":3}` | Startup probe timing. The chart sets the path (`<contextPath>actuator/health/liveness`) and port. |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after SIGTERM. The admin stops its scheduler threads within a few seconds. |
| timezone | string | `"UTC"` | Time zone of the admin (`TZ` and the JDBC `serverTimezone`). Cron expressions run in this time zone. The image's own default is `PRC` (China). |
| tolerations | list | `[]` | Tolerations. |
