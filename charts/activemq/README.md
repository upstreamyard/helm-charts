# ActiveMQ Helm chart: Apache ActiveMQ Classic on Kubernetes

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square) ![AppVersion: 6.4.0](https://img.shields.io/badge/AppVersion-6.4.0-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for **[Apache ActiveMQ Classic](https://github.com/apache/activemq)**, the open-source JMS message broker (OpenWire, AMQP, STOMP, MQTT, WebSocket). It runs a single broker or a **highly available master/slave pair**, either on PostgreSQL (no shared storage needed) or on a shared volume. Logins are **required by default** with generated passwords, and Prometheus metrics, a ServiceMonitor and `helm test` are included. It covers ActiveMQ **6.3, 6.2 and 5.19** through the [`upstreamyard/activemq`](https://github.com/upstreamyard/activemq) image. It also replaces the discontinued Bitnami ActiveMQ image on Kubernetes.

> Community chart by **upstreamyard**, not an official Apache ActiveMQ chart. Apache ActiveMQ is licensed under Apache-2.0. Apache, Apache ActiveMQ and ActiveMQ are trademarks of the Apache Software Foundation.

**AI agents and coding assistants:** this README is the complete reference. The image's [`AGENTS.md`](https://github.com/upstreamyard/activemq/blob/main/AGENTS.md) lists the deployment rules, and [`llms.txt`](https://github.com/upstreamyard/activemq/blob/main/llms.txt) indexes all docs.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install activemq upstreamyard/activemq
```

Or from the OCI registry:

```bash
helm install activemq oci://ghcr.io/upstreamyard/charts/activemq
```

The install notes show the client URL and the commands that print the generated passwords. Then check that messages flow:

```bash
helm test activemq
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install activemq upstreamyard/activemq --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## What the chart does

- **StatefulSet** with stable pod names (`<release>-activemq-0`, `-1`) and a volume per broker for the KahaDB message store.
- **Security:**
  - generated admin and app passwords in a Secret, kept across upgrades;
  - no anonymous clients;
  - non-root (UID 10001), read-only root filesystem, all capabilities dropped, no ServiceAccount token.
- **Users:**
  - the **admin** user may do everything, including the web console;
  - the **app** user may send to, receive from and create any queue or topic, without web console access.
- **Transports:** OpenWire (61616) by default; add `amqp`, `stomp`, `mqtt`, `ws` in `transports`.
- **Master/slave:** with `replicaCount: 2`, one broker is active and the other waits and takes over. Probes use the image's `broker-state` command, so the waiting standby counts as healthy and rolling updates don't stall on it. There's also a PodDisruptionBudget and soft anti-affinity.
- **Graceful shutdown:** the broker stops cleanly on `SIGTERM`, within the 60-second grace period.
- **Metrics:** `metrics.enabled` serves broker, per-queue/topic and JVM metrics on port 9404; `metrics.serviceMonitor.enabled` adds a ServiceMonitor.
- **Your own config:** `configFiles` and `configSecrets` place files such as `activemq.xml`, `users.properties` or keystores in `/etc/activemq`.

## Deployment modes

### Single broker (default)

One broker with KahaDB on a PersistentVolumeClaim. If the pod or node fails, Kubernetes restarts the broker on the same volume.

```yaml
persistence:
  size: 20Gi
resources:
  limits:
    memory: 2Gi
```

### High availability with PostgreSQL (JDBC master/slave)

Two brokers share one database; no `ReadWriteMany` storage is needed. The image includes the PostgreSQL driver.

```yaml
replicaCount: 2
store:
  type: jdbc
jdbc:
  url: jdbc:postgresql://postgres.example.svc:5432/activemq
  user: activemq
  existingSecret: activemq-db          # key: password
persistence:
  enabled: false                       # messages live in the database
```

- **Tested in kind:** deleting the active pod moved the work to the standby in 2 seconds, without message loss. A rolling `helm upgrade` under load lost no messages either.
- **One database per installation.** Brokers that share the lock table act as one master/slave group, so a second installation on the same database only waits as a standby.
- ActiveMQ creates the tables `ACTIVEMQ_MSGS`, `ACTIVEMQ_ACKS` and `ACTIVEMQ_LOCK` on the first start, and later starts log the harmless warning `Could not create JDBC tables; they could already exist`.
- JDBC is slower than KahaDB. Scheduled messages (`broker.scheduler`) stay on the pod's own storage and don't move to the standby.

### High availability with a shared volume

Both brokers use one `ReadWriteMany` volume with working file locks (e.g. NFSv4 or CephFS). The broker that holds the KahaDB lock is active:

```yaml
replicaCount: 2
persistence:
  existingClaim: activemq-shared       # ReadWriteMany
```

- **Tested in kind** with a hostPath volume: when the active pod was deleted or its broker crashed, the restarted pod usually got the lock back first. A broker was active again after about 3 seconds, without message loss.
- The standby takes over when the active broker can't come back, e.g. when its node fails (not tested in a single-node cluster).

## Connecting clients

- **Single broker:** `tcp://<release>-activemq.<namespace>.svc:61616`.
- **Master/slave:** use the failover URL from the install notes. It lists every broker through the headless Service, for example:

  ```
  failover:(tcp://activemq-0.activemq-headless.messaging.svc:61616,tcp://activemq-1.activemq-headless.messaging.svc:61616)
  ```

  Only the active broker accepts connections, and JMS clients with a failover URL reconnect by themselves. The regular Service includes the standby too, so clients of other protocols (AMQP, STOMP, MQTT) should retry on connection errors.
- **Web console:** `kubectl port-forward svc/<release>-activemq 8161`, then open http://localhost:8161/admin as the admin user, or use `ingress.enabled`.

## Choosing the ActiveMQ version

The chart defaults to the newest ActiveMQ 6.3. Pick another supported release line with `image.tag`:

| `image.tag` | ActiveMQ | Clients |
|---|---|---|
| (default) or `6.3` | 6.3.x | `jakarta.jms` (Spring Boot 3, Jakarta EE 9+) |
| `6.2` | 6.2.x | `jakarta.jms` |
| `5.19` | 5.19.x | `javax.jms` (Spring Boot 2, Java EE 8) |

An upgrade from 6.2 to 6.3 on the same volume kept all queued messages in our test.

## Production example

```yaml
# values-prod.yaml
replicaCount: 2
auth:
  existingSecret: activemq-auth        # keys: admin-password, app-password
transports: [openwire, amqp]
store:
  type: jdbc
jdbc:
  url: jdbc:postgresql://postgres.example.svc:5432/activemq
  user: activemq
  existingSecret: activemq-db
persistence:
  enabled: false
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    memory: 2Gi
podAntiAffinityPreset: hard
```

## Your own configuration

- **Broker settings:** put a complete `activemq.xml` in `configFiles`. The chart's `transports`, `store`, `broker` and `webConsole` values are then ignored. Keep `<jaasAuthenticationPlugin configuration="activemq"/>` for logins and `id="broker"` on `<broker>`. Start from the image's [default activemq.xml](https://github.com/upstreamyard/activemq/blob/main/conf/activemq.xml).
- **More users or groups:** a Secret with `users.properties` and `groups.properties` in `configSecrets`. The chart's admin and app passwords are then only used by `helm test`, so keep matching entries.
- **Logging:** `log4j2.properties` in `configFiles`.
- **Other image settings:** `extraEnv`, e.g. `ACTIVEMQ_HEALTHCHECK_PORT`. The [image README](https://github.com/upstreamyard/activemq#configuration) lists them all.

## FAQ

**Is there an official ActiveMQ Helm chart?** Apache doesn't publish one for ActiveMQ Classic. This chart is maintained by upstreamyard together with the image.

**What replaces the Bitnami ActiveMQ image on Kubernetes?** This chart with our image. Bitnami's `ACTIVEMQ_PASSWORD` becomes `auth.adminPassword`, or let the chart generate one.

**Is this ActiveMQ Artemis?** No, it's ActiveMQ **Classic** (5.x/6.x). Artemis is a different broker.

**How do I run ActiveMQ highly available on Kubernetes?** `replicaCount: 2` with `store.type: jdbc` and a PostgreSQL database. See [Deployment modes](#deployment-modes).

**How do I monitor ActiveMQ with Prometheus?** `metrics.enabled=true` and `metrics.serviceMonitor.enabled=true`.

**Why does only one pod accept connections?** That's how ActiveMQ Classic master/slave works: one active broker and a waiting standby. Use the failover URL.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Replaces `podAntiAffinityPreset`. |
| auth.adminPassword | string | `""` | Password of the admin user. Generated when empty, and kept across upgrades. Ignored when `existingSecret` is set. |
| auth.adminPasswordKey | string | `"admin-password"` | Key in `existingSecret` with the admin password. |
| auth.adminUser | string | `"admin"` | Name of the admin user. |
| auth.appPassword | string | `""` | Password of the application user. Generated when empty, and kept across upgrades. Ignored when `existingSecret` is set. |
| auth.appPasswordKey | string | `"app-password"` | Key in `existingSecret` with the app password. |
| auth.appUser | string | `"app"` | Name of the application user. Empty: no application user. |
| auth.existingSecret | string | `""` | Existing Secret with the passwords (recommended for production). |
| broker.name | string | `""` | Broker name (JMX, metrics label, networks of brokers). Empty: `localhost`, ActiveMQ's default. |
| broker.scheduler | bool | `false` | Enable scheduled and delayed messages (`AMQ_SCHEDULED_DELAY`, ...). Scheduled messages are kept on the pod's volume, also with `store.type: jdbc`, so they don't move to a standby. |
| broker.storeLimit | string | `""` | Disk limit for persistent messages, e.g. `20 gb`. Empty: 100 gb, which ActiveMQ lowers to the free space of the volume. |
| broker.tempLimit | string | `""` | Disk limit for temporary storage, e.g. `5 gb`. Empty: 50 gb, lowered like `storeLimit`. |
| configFiles | object | `{}` | Your own config files, mounted in /etc/activemq where they replace the image's defaults of the same name, e.g. `activemq.xml` or `log4j2.properties`. With your own `activemq.xml`, `transports`, `store`, `broker` and `webConsole` are ignored. |
| configSecrets | list | `[]` | Secrets whose keys are added as files to /etc/activemq, like `configFiles`, for sensitive files: `users.properties` and `groups.properties` (more users), keystores for TLS, or an `activemq.xml` with credentials. |
| extraEnv | list | `[]` | Extra environment variables, e.g. other `ACTIVEMQ_*` settings of the image. |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts. Not inside /etc/activemq: use `configFiles` or `configSecrets` for files there. |
| extraVolumes | list | `[]` | Extra volumes, e.g. a Secret with a TLS keystore. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"upstreamyard/activemq"` | Image repository. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion (newest ActiveMQ 6.3). Use e.g. `6.2` or `5.19` (javax.jms clients) for the other release lines. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the web console. |
| ingress.hosts | list | `[{"host":"activemq.example.com","paths":[{"path":"/","pathType":"Prefix"}]}]` | Ingress hosts and paths. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| javaOpts | string | `""` | Extra Java options (`ACTIVEMQ_OPTS`), added after the image's own. |
| jdbc.driver | string | `""` | JDBC driver class. Empty: `org.postgresql.Driver`. Other databases need an image with their driver. |
| jdbc.existingSecret | string | `""` | Existing Secret with the database password. |
| jdbc.existingSecretPasswordKey | string | `"password"` | Key in `existingSecret` with the database password. |
| jdbc.password | string | `""` | Database password. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| jdbc.url | string | `""` | JDBC URL, e.g. `jdbc:postgresql://postgres:5432/activemq`. |
| jdbc.user | string | `""` | Database user. Needs to create tables on the first start. |
| memoryOpts | string | `""` | Heap options (`ACTIVEMQ_OPTS_MEMORY`). Empty: 60% of the memory limit. |
| metrics.enabled | bool | `false` | Expose Prometheus metrics on port 9404 (broker, per-queue/topic and JVM metrics). |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor (needs the monitoring.coreos.com CRDs). |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the label your Prometheus selects ServiceMonitors by. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes of the per-broker claims. |
| persistence.annotations | object | `{}` | Annotations for the per-broker claims. |
| persistence.enabled | bool | `true` | Create a PersistentVolumeClaim per broker. If false, an `emptyDir` is used and KahaDB messages are lost when the pod is deleted. |
| persistence.existingClaim | string | `""` | Use an existing claim for all brokers instead. For master/slave with `store.type: kahadb` it must be `ReadWriteMany` with working file locks (e.g. NFSv4). |
| persistence.size | string | `"8Gi"` | Size of the per-broker claims. |
| persistence.storageClass | string | `""` | Storage class. Empty: the cluster default. |
| podAnnotations | object | `{}` | Pod annotations. |
| podAntiAffinityPreset | string | `"soft"` | Spread brokers across nodes: `soft` (preferred), `hard` (required) or `""` (off). Ignored when `affinity` is set. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget (`maxUnavailable: 1`) when `replicaCount` is greater than 1. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| priorityClassName | string | `""` | Priority class name. |
| probes.liveness.failureThreshold | int | `4` | Liveness probe failures before the container is restarted. |
| probes.liveness.periodSeconds | int | `15` | Liveness probe period in seconds. |
| probes.readiness.failureThreshold | int | `2` | Readiness probe failures before the pod is taken out of the Service. |
| probes.readiness.periodSeconds | int | `5` | Readiness probe period in seconds. |
| probes.startup.failureThreshold | int | `120` | Startup probe failures before the container is restarted (5 s × 120 = 10 minutes for a large KahaDB to recover). |
| probes.startup.periodSeconds | int | `5` | Startup probe period in seconds. |
| replicaCount | int | `1` | Number of brokers. ActiveMQ Classic runs one active broker; further replicas are standbys that take over when it stops (master/slave). More than 1 requires `store.type: jdbc` or a shared volume (`persistence.existingClaim` with `ReadWriteMany`). |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"1Gi"}}` | Resources. The heap is 60% of the memory limit, and ActiveMQ keeps up to 70% of the heap in memory for messages. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Service annotations. |
| service.type | string | `"ClusterIP"` | Service type for clients and the web console. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: the full resource name. |
| store.type | string | `"kahadb"` | Message store: `kahadb` (files on the pod's volume) or `jdbc` (a database; master/slave without shared storage). |
| terminationGracePeriodSeconds | int | `60` | Seconds to let the broker shut down cleanly. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| transports | list | `["openwire"]` | Protocols the broker accepts: `openwire` (61616, JMS), `amqp` (5672), `stomp` (61613), `mqtt` (1883), `ws` (61614, WebSocket). The first one is used for probes and `helm test`. |
| webConsole.enabled | bool | `true` | Enable the web console and Jolokia on port 8161 (admin user only). |
