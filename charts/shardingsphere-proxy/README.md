# ShardingSphere-Proxy Helm chart

![Version: 0.1.1](https://img.shields.io/badge/Version-0.1.1-informational?style=flat-square) ![AppVersion: 5.5.3](https://img.shields.io/badge/AppVersion-5.5.3-informational?style=flat-square)

Helm chart for [Apache ShardingSphere-Proxy](https://github.com/apache/shardingsphere), the database proxy that adds sharding, read/write splitting, encryption and masking in front of MySQL and PostgreSQL. Applications connect to it like to a normal MySQL or PostgreSQL server. It uses the image [`upstreamyard/shardingsphere-proxy`](https://github.com/upstreamyard/shardingsphere-proxy), which includes the MySQL JDBC driver.

> Community chart by **upstreamyard**, not an official Apache ShardingSphere chart. Apache ShardingSphere is licensed under Apache-2.0; the image also contains MySQL Connector/J (GPL-2.0 with the Universal FOSS Exception). Apache, Apache ShardingSphere and ShardingSphere are trademarks of the Apache Software Foundation.

## Install

Write your users and logical databases into a values file:

```yaml
# my-values.yaml
users:
  - user: admin@%
    password: change-me
    admin: true            # may run DistSQL, ShardingSphere's admin SQL
  - user: app@%
    password: change-me-too
databases:
  sharding_db: |
    dataSources:
      ds_0:
        url: jdbc:mysql://mysql-0.example:3306/ds_0?sslMode=REQUIRED
        username: shardingsphere
        password: secret
      ds_1:
        url: jdbc:mysql://mysql-1.example:3306/ds_1?sslMode=REQUIRED
        username: shardingsphere
        password: secret
    rules:
      - !SHARDING
        tables:
          t_order:
            actualDataNodes: ds_${0..1}.t_order
            databaseStrategy:
              standard:
                shardingColumn: user_id
                shardingAlgorithmName: by_user_id
        shardingAlgorithms:
          by_user_id:
            type: INLINE
            props:
              algorithm-expression: ds_${user_id % 2}
```

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install shardingsphere-proxy upstreamyard/shardingsphere-proxy -f my-values.yaml
```

Or from the OCI registry:

```bash
helm install shardingsphere-proxy oci://ghcr.io/upstreamyard/charts/shardingsphere-proxy -f my-values.yaml
```

Applications then connect to the Service on port 3307 as user `app`, database `sharding_db`, with a MySQL client or driver. With PostgreSQL backends, they use a PostgreSQL client or driver instead.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install shardingsphere-proxy upstreamyard/shardingsphere-proxy --verify --keyring upstreamyard.gpg -f my-values.yaml
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **Your backend databases:** MySQL, MariaDB or PostgreSQL (tested: MySQL 8.4 and, with the image, MariaDB 11.4 and PostgreSQL 17). This chart does not deploy them.
- **For more than one replica:** ZooKeeper (tested: 3.9). This chart does not deploy it.

## What the chart does

- **Configuration:** the chart writes `global.yaml` (users, mode, `props`, `globalConfig`) and one `database-<name>.yaml` per entry in `databases` into a Secret, and mounts it at `/opt/shardingsphere-proxy/conf`. The entries in `databases` are text, because ShardingSphere's rules use YAML tags like `!SHARDING`. ShardingSphere's documentation describes [data sources and all rules](https://shardingsphere.apache.org/document/current/en/user-manual/shardingsphere-proxy/yaml-config/).
- **Users are required:** without them, ShardingSphere accepts `root`/`root` as admin from any host, so the chart refuses to install without `users` (or `existingSecret`).
- **MySQL and MariaDB URLs** need `sslMode=REQUIRED` (or `VERIFY_IDENTITY`). ShardingSphere turns TLS off by default, and MySQL 8 then refuses the login with `Public Key Retrieval is not allowed`. Use `jdbc:mysql://` URLs for MariaDB servers too.
- **Probes:** TCP on port 3307. The port opens once the configuration is loaded and all backend databases are connected. If a backend is unreachable at startup, the proxy exits and the container restarts until it is reachable.
- **Restarts on change:** changing the values restarts the pods (checksum annotation). With `existingSecret`, restart them yourself (`kubectl rollout restart`).
- **Shutdown:** on `SIGTERM` the proxy closes its client connections within a second, so the pod first waits `preStopSleepSeconds` (5) while it's removed from the Service. In our test, a rolling restart of two pods under a constant stream of new connections had no failed connection. Connections that are open when their pod stops are closed; clients and connection pools have to reconnect.
- **XA transactions:** set `globalConfig.transaction` to `{defaultType: XA, providerType: Atomikos}`. In our test, a transaction across two MySQL databases committed on both and rolled back on both. Atomikos writes its transaction log to an emptyDir at `/opt/shardingsphere-proxy/logs`. The log survives container restarts but not a replaced pod, so Atomikos can't finish transactions that a deleted pod left in doubt. We haven't tested crash recovery.
- **Memory:** the Java heap is 80% of the memory limit (2Gi by default).
- **Security:** runs as UID 10001 with a read-only root filesystem (`/tmp` and `logs` are emptyDirs), drops all capabilities, and doesn't mount a ServiceAccount token.
- **`helm test`** connects to the Service and, with MySQL backends, checks the proxy's greeting.

## Standalone and Cluster mode

| | `mode: Standalone` (default) | `mode: Cluster` |
|---|---|---|
| Replicas | 1 | any number; a PodDisruptionBudget keeps all but one running |
| Needs | nothing | ZooKeeper (`cluster.zookeeper.serverLists`) |
| Source of configuration | the values, on every start | the values on the **first** start; after that, ZooKeeper |
| Changes made with DistSQL | lost when the pod restarts | kept in ZooKeeper and seen by all pods at once |

```yaml
replicaCount: 3
mode: Cluster
cluster:
  zookeeper:
    serverLists: zookeeper-0.zookeeper:2181,zookeeper-1.zookeeper:2181,zookeeper-2.zookeeper:2181
```

**Changing the configuration in Cluster mode:** once ZooKeeper holds a configuration (in `cluster.namespace`, by default the release's full name), ShardingSphere ignores the values completely. That includes `users` and their passwords, for which DistSQL has no command. You can change the configuration in two ways:

- **Rules and data sources:** use DistSQL as an admin user (e.g. `CREATE SHARDING TABLE RULE …`). The changes apply to all pods at once and survive restarts.
- **Everything else, e.g. users:** set a new `cluster.namespace` with `helm upgrade`. ShardingSphere then starts again from the values, and DistSQL changes from the old namespace are not carried over. During the rollout, old pods still serve the old configuration until they stop. The old namespace stays in ZooKeeper until you delete it.

Uninstalling and reinstalling a release with the same name reuses the old namespace and its configuration, so set a new `cluster.namespace` if you want a fresh start.

## Your own configuration files

To manage the files yourself, put `global.yaml` and the `database-*.yaml` files (optionally `logback.xml`) into a Secret and set `existingSecret`. The chart then ignores `users`, `mode`, `cluster`, `props`, `globalConfig` and `databases`, and doesn't check them.

```bash
kubectl create secret generic proxy-config --from-file=conf/
helm install shardingsphere-proxy upstreamyard/shardingsphere-proxy --set existingSecret=proxy-config
```

## Extra drivers and plugins

Jar files in `/opt/shardingsphere-proxy/ext-lib` are on the classpath, e.g. other JDBC drivers or your own sharding algorithms. An init container can download them into an emptyDir:

```yaml
initContainers:
  - name: ext-lib
    image: busybox:1.37
    command: ["wget", "-q", "-O", "/ext-lib/my-plugin.jar", "https://example.com/my-plugin.jar"]
    volumeMounts:
      - { name: ext-lib, mountPath: /ext-lib }
extraVolumes:
  - name: ext-lib
    emptyDir: {}
extraVolumeMounts:
  - { name: ext-lib, mountPath: /opt/shardingsphere-proxy/ext-lib, readOnly: true }
```

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
mode: Cluster
cluster:
  zookeeper:
    serverLists: zookeeper-0.zookeeper:2181,zookeeper-1.zookeeper:2181,zookeeper-2.zookeeper:2181
users:
  - user: admin@%
    password: <generated>
    admin: true
  - user: app@%
    password: <generated>
databases:
  sharding_db: |
    dataSources: ...
    rules: ...
service:
  type: LoadBalancer        # only if clients run outside the cluster
resources:
  requests:
    cpu: "2"
    memory: 4Gi
  limits:
    memory: 4Gi
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: shardingsphere-proxy
```

Keep the values file out of version control, or use `existingSecret`: it contains passwords.

## Known issues

- **ShardingSphere 5.5.3** ships optional plugins without the libraries they need (Hive, Seata AT transactions, Narayana XA). The image removes them, so these features are not available. XA transactions with Atomikos work (below).
- `jdbc:mariadb://` URLs make ShardingSphere 5.5.3 fail at startup; use `jdbc:mysql://` for MariaDB servers.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| cluster.namespace | string | `""` | ZooKeeper namespace (root node) of this proxy cluster. Defaults to the release's full name. In Cluster mode, ShardingSphere uses these values only while the namespace is empty, i.e. on the first start; set a new namespace to apply changed values (see README). |
| cluster.props | object | `{"maxRetries":3,"operationTimeoutMilliseconds":500,"retryIntervalMilliseconds":500,"timeToLiveSeconds":60}` | Further ZooKeeper repository properties. |
| cluster.zookeeper.serverLists | string | `""` | ZooKeeper servers, comma-separated, e.g. `zookeeper-0.zookeeper:2181,zookeeper-1.zookeeper:2181`. Required for `mode: Cluster`. |
| databases | object | `{}` | Logical databases: name → content of `database-<name>.yaml` without `databaseName` (the chart adds it). Given as text, because ShardingSphere's rules use YAML tags like `!SHARDING`. Holds passwords, so the chart stores it in a Secret. |
| existingSecret | string | `""` | Name of an existing Secret with the complete configuration: `global.yaml` and `database-*.yaml` files (and optionally `logback.xml`). Replaces `users`, `privilege`, `mode`, `cluster`, `props`, `globalConfig` and `databases`. |
| extraEnv | list | `[]` | Extra environment variables, e.g. `JVM_OPTS`. |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for the proxy container. Jar files in `/opt/shardingsphere-proxy/ext-lib` are on the classpath. |
| extraVolumes | list | `[]` | Extra volumes for the pods. |
| fullnameOverride | string | `""` | Override the full resource name. |
| globalConfig | object | `{}` | Further top-level sections of `global.yaml`, e.g. `transaction`, `sqlParser`, `sqlFederation`, `logging`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"upstreamyard/shardingsphere-proxy"` | Image repository. upstreamyard's image includes the MySQL JDBC driver. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| initContainers | list | `[]` | Init containers, e.g. to put extra JDBC drivers or plugins into a volume mounted at `/opt/shardingsphere-proxy/ext-lib`. |
| livenessProbe | object | `{"failureThreshold":3,"periodSeconds":10,"tcpSocket":{"port":"proxy"},"timeoutSeconds":3}` | Liveness probe. |
| mode | string | `"Standalone"` | `Standalone` (one pod; configuration from these values on every start) or `Cluster` (several pods sharing their configuration through ZooKeeper). |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget when `replicaCount` is greater than 1. |
| podDisruptionBudget.maxUnavailable | int | `1` | Pods that may be unavailable during voluntary disruptions. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":10001,"runAsGroup":10001,"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image runs as UID 10001. |
| preStopSleepSeconds | int | `5` | Seconds to wait before the container gets SIGTERM, so the pod is removed from the Service first. The proxy then closes its client connections within a second. 0 disables it. |
| privilege | object | `{"type":"ALL_PERMITTED"}` | Privilege provider (`authority.privilege`). `ALL_PERMITTED` gives every user access to every logical database; `DATABASE_PERMITTED` limits users through `props.user-database-mappings`. |
| props | object | `{}` | Properties (`props` in `global.yaml`), e.g. `sql-show: true`, `proxy-frontend-max-connections`. The port is set by the chart (3307). |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":5,"tcpSocket":{"port":"proxy"},"timeoutSeconds":3}` | Readiness probe. |
| replicaCount | int | `1` | Number of proxy pods. More than 1 needs `mode: Cluster` with ZooKeeper, so all pods share one configuration. |
| resources | object | `{"limits":{"memory":"2Gi"},"requests":{"cpu":"500m","memory":"2Gi"}}` | Resources. The Java heap is 80% of the memory limit (ShardingSphere's default), so always set one. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The root filesystem is read-only; `/tmp` is an emptyDir. |
| service.annotations | object | `{}` | Service annotations. |
| service.port | int | `3307` | Service port. Clients connect here with a MySQL or PostgreSQL client, depending on the backend databases. |
| service.type | string | `"ClusterIP"` | Service type. Use `LoadBalancer` for clients outside the cluster. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. ShardingSphere does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| startupProbe | object | `{"failureThreshold":60,"periodSeconds":2,"tcpSocket":{"port":"proxy"},"timeoutSeconds":3}` | Startup probe. The port opens once the configuration is loaded and the backend databases are connected (if a backend is unreachable, the proxy exits and the container restarts). |
| terminationGracePeriodSeconds | int | `30` | Seconds Kubernetes waits after SIGTERM. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints, e.g. to spread the pods across nodes or zones. |
| users | list | `[]` | Users that may connect (`authority.users` in `global.yaml`): `user` (`name@host`, `%` = any host), `password`, and `admin: true` for users that may run DistSQL. Required unless `existingSecret` is set, because without users ShardingSphere accepts `root`/`root` as admin. |
