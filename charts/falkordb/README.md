# FalkorDB Helm chart: FalkorDB graph database on Kubernetes

![Version: 0.1.4](https://img.shields.io/badge/Version-0.1.4-informational?style=flat-square) ![AppVersion: 6.0.3](https://img.shields.io/badge/AppVersion-6.0.3-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for **[FalkorDB](https://github.com/FalkorDB/FalkorDB)**, the low-latency graph database for knowledge graphs, GraphRAG and AI agent memory, queried with openCypher. It runs a single instance or a **highly available primary with replicas and Redis Sentinel**, which promotes a replica automatically when the primary fails. A **password is required by default**, graphs are kept with AOF and RDB persistence, and Prometheus metrics, a ServiceMonitor and `helm test` are included. It uses FalkorDB's official `falkordb/falkordb-server` image (FalkorDB **6.0**), runs it as non-root on a read-only root filesystem, and replaces the Bitnami Redis chart workaround for running FalkorDB on Kubernetes.

> Community chart by **upstreamyard**, not an official FalkorDB chart. FalkorDB is licensed under the Server Side Public License (SSPL-1.0); this chart is Apache-2.0. FalkorDB is a trademark of FalkorDB Ltd.

**AI agents and coding assistants:** this README is the complete reference for the chart. FalkorDB itself (Cypher, clients, configuration parameters) is documented at [docs.falkordb.com](https://docs.falkordb.com).

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install falkordb upstreamyard/falkordb
```

Or from the OCI registry:

```bash
helm install falkordb oci://ghcr.io/upstreamyard/charts/falkordb
```

The install notes show the address and the command that prints the generated password. Then check that graphs can be written and read:

```bash
helm test falkordb
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install falkordb upstreamyard/falkordb --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## What the chart does

- **StatefulSet** with stable pod names (`<release>-falkordb-0`, `-1`, …) and a volume per pod for `/var/lib/falkordb/data`.
- **Security:**
  - a generated password (`requirepass`) in a Secret, kept across upgrades, also required by Sentinel;
  - non-root (UID 999, the image's `falkordb` user), read-only root filesystem, all capabilities dropped, no ServiceAccount token. Works in namespaces with Pod Security `restricted`.
- **Durability:** AOF (`appendfsync everysec`) and RDB snapshots by default; FalkorDB saves on shutdown within the 60-second grace period.
- **Replication with Sentinel** (`architecture: replication`):
  - one primary and replicas, plus a Sentinel container in every pod; pods and Sentinels address each other by stable DNS names, so changing pod IPs don't matter;
  - planned restarts (rolling upgrades, `kubectl delete pod`, node drains) **hand over the primary role first**: writes are paused, the replicas catch up, a replica is promoted, and the old primary follows it;
  - the primary only accepts writes while at least one replica is connected (`replication.minReplicasToWrite`), so a primary that was cut off or frozen can't accept writes that would be lost;
  - a pod that comes back with an empty volume never becomes primary while another pod still has the data; it waits until Sentinel promotes a pod with data, then copies it;
  - each Sentinel keeps its state (the last primary and epochs) on the pod's volume and knows every other pod, so after a full outage the pods agree on the last primary, and Sentinel can promote a replica even when that primary doesn't come back;
  - PodDisruptionBudget and soft anti-affinity across nodes.
- **Probes:** a pod is ready only when FalkorDB has loaded its data and, on replicas, is in sync with the primary. The startup probe allows 30 minutes for loading large graphs.
- **Metrics:** `metrics.enabled` adds `redis_exporter` on port 9121; `metrics.serviceMonitor.enabled` adds a ServiceMonitor.

## Why this chart

FalkorDB's own Helm repository has charts for the browser UI and the SQL import tool, but not for the database. The other ways to run it on Kubernetes:

| | This chart | Bitnami Redis chart with the FalkorDB image | KubeBlocks FalkorDB addon |
|---|---|---|---|
| FalkorDB version | 6.0 (official `falkordb-server` image, updated with each release) | `latest` tag in FalkorDB's instructions | 4.12.5 (chart 1.2.0-alpha.0) |
| Extra requirements | none | `allowInsecureImages: true`; Bitnami's `redis-cluster` option uses the frozen `bitnamilegacy` image | the KubeBlocks operator |
| HA with automatic failover | Sentinel, writes paused and handed over on planned restarts | Sentinel | replication with switchover |
| Backups | not included (RDB/AOF on the volumes) | not included | BGSAVE and AOF backups |
| Sharding (Redis Cluster) | not yet | `redis-cluster` chart | yes |

## Deployment modes

### Single instance (default)

One FalkorDB pod with its graphs on a PersistentVolumeClaim. If the pod or node fails, Kubernetes restarts it on the same volume; in our test, a 2,000-node graph was back after the pod was deleted.

```yaml
persistence:
  size: 20Gi
resources:
  requests:
    cpu: "1"
    memory: 4Gi
  limits:
    memory: 4Gi
```

### High availability with Sentinel

```yaml
architecture: replication
replicaCount: 3           # one primary, two replicas, three Sentinels
persistence:
  size: 20Gi
```

At least 3 pods: with 2, the remaining Sentinel has no majority and can't promote the replica. The first install makes pod 0 the primary.

**Tested in kind** (3 nodes, 3 pods, a client writing once per second through Sentinel, comparing every acknowledged write with the database afterwards):

| Event | Writes failed | Acknowledged writes lost |
|---|---|---|
| Rolling `helm upgrade` from FalkorDB 6.0.1 to 6.0.2 (66 s) | 1 | 0 |
| `kubectl delete pod` on the primary (pod gone in 4 s) | 1 | 0 |
| Primary's node frozen (`docker pause`) for 60 s | for 9 s, until a replica was promoted | 0 |
| Primary restarted with an empty volume | for 8 s; the pod waited, then copied the data from the promoted replica | 0 |
| Replica's volume and pod deleted | none; the replica copied the data from the primary | 0 |
| All pods stopped and started again | (no client) | 0 |
| All pods stopped, the primary's volume deleted, started again | (no client); ready again after 20 s with a promoted replica | 0 |

Without the write pause in the handover, the same pod deletion lost 11 acknowledged writes in our test, and without `minReplicasToWrite` a frozen primary lost 11 writes it accepted after it came back. Replication is asynchronous, so a primary that crashes can still lose the writes of its last moment that hadn't reached a replica.

## Connecting clients

The install notes print the exact addresses.

- **Single instance:** `<release>-falkordb.<namespace>.svc:6379`.
- **Replication:** connect to **Sentinel** at `<release>-falkordb.<namespace>.svc:26379` with the primary name `falkordb` (`sentinel.masterSet`) and the same password. Clients then always write to the current primary and switch after a failover.
- **Read-only queries** (`GRAPH.RO_QUERY`) may also use port 6379 of the same Service, which spreads them over all ready pods. Writes there fail on replicas with `READONLY`.

**Python (`falkordb`):** the client detects Sentinel by itself:

```python
from falkordb import FalkorDB
db = FalkorDB(host="falkordb-falkordb.default.svc", port=26379, password=password)
graph = db.select_graph("social")
```

It doesn't pass socket timeouts to its Sentinel connections, though (falkordb 1.2.0). When the primary's node froze in our test, such a client hung for minutes. For production, build the Sentinel connection with redis-py and hand it to FalkorDB, which recovered in about 9 s in the same test:

```python
from redis.sentinel import Sentinel
from falkordb import FalkorDB

timeouts = {"socket_timeout": 2, "socket_connect_timeout": 2}
sentinel = Sentinel([("falkordb-falkordb.default.svc", 26379)],
                    sentinel_kwargs={"password": password, **timeouts},
                    password=password, **timeouts)
db = FalkorDB(connection_pool=sentinel.master_for("falkordb").connection_pool)
```

Retry a write that fails with a connection error, timeout or `READONLY`: that is the failover. Clients in other languages can use their Redis client's Sentinel support in the same way (not tested here).

**From your machine:** `kubectl port-forward svc/<release>-falkordb 6379`, then e.g. `redis-cli -a <password> GRAPH.QUERY social "MATCH (n) RETURN count(n)"`. With replication, this reaches any pod, so use it for reads.

## Configuration

- **FalkorDB settings** (`THREAD_COUNT`, `TIMEOUT_MAX`, `QUERY_MEM_CAPACITY`, …): the `config` map, passed to the module. The defaults are those of the official image, including a 1-second timeout for read queries (`TIMEOUT 1000`). Set a key to `null` to remove it:

  ```yaml
  config:
    TIMEOUT: null            # no 1-second read timeout
    TIMEOUT_DEFAULT: 30000   # 30 s for reads and writes
    THREAD_COUNT: 4
  ```

- **Redis settings** (`maxclients`, `aclfile`, …): `extraConfig`, added after the chart's own lines.
- **Durability:** `durability.appendonly`, `durability.appendfsync` and `durability.save`.
- **CSV import (`LOAD CSV`):** mount the files and point `IMPORT_FOLDER` at them; `file://people.csv` then reads `/import/people.csv`:

  ```yaml
  config:
    IMPORT_FOLDER: /import/
  extraVolumes:
    - name: csv
      configMap:
        name: people-csv
  extraVolumeMounts:
    - name: csv
      mountPath: /import
  ```

## Production example

```yaml
# values-prod.yaml
architecture: replication
replicaCount: 3
auth:
  existingSecret: falkordb-auth        # key: password
config:
  MAX_QUEUED_QUERIES: 25
  TIMEOUT: null
  TIMEOUT_MAX: 60000
  TIMEOUT_DEFAULT: 10000
  RESULTSET_SIZE: 10000
  THREAD_COUNT: 4
persistence:
  size: 50Gi
resources:
  requests:
    cpu: "4"
    memory: 16Gi
  limits:
    memory: 16Gi
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
podAntiAffinityPreset: hard
```

Size the memory limit for the graphs plus headroom: snapshots and AOF rewrites fork the process, and pages changed meanwhile are copied.

## Known issues

- **All volumes lost:** the chart protects against losing one pod's volume. If every pod's volume is lost, the graphs are gone; keep backups of the RDB/AOF files or volume snapshots.
- **Generated password after uninstall:** `helm uninstall` deletes the chart's Secret; a new install generates a new password (the graphs on the kept volumes are unaffected). Use `auth.existingSecret` in production.
- **Argo CD and other `helm template` tools** can't read the existing Secret and generate a new password on every render. Set `auth.existingSecret` or `auth.password`.
- **`IMPORT_FOLDER` default:** FalkorDB 6.0.2 reports `/var/lib/FalkorDB/import/`, which doesn't exist in the image. Set it as shown above.
- **Not included yet:** Redis Cluster (sharding), TLS and the experimental Bolt protocol.

## FAQ

**Is there an official FalkorDB Helm chart?** No. FalkorDB's Helm repository has charts for the browser and the SQL import tool, and its documentation installs the Bitnami Redis chart with the FalkorDB image. This chart is maintained by upstreamyard.

**What replaces the Bitnami Redis chart for FalkorDB?** This chart. It runs the official FalkorDB image without `allowInsecureImages`, loads the module itself, and supports Sentinel HA.

**How do I run FalkorDB highly available on Kubernetes?** `architecture: replication` with `replicaCount: 3`, and connect through Sentinel. See [Deployment modes](#deployment-modes).

**How do I monitor FalkorDB with Prometheus?** `metrics.enabled=true` and `metrics.serviceMonitor.enabled=true`.

**Why do my queries fail with `Query timed out`?** The official image sets `TIMEOUT 1000`, so read queries stop after 1 second. Raise or remove it in `config` (see [Configuration](#configuration)).

**Why do writes fail with `NOREPLICAS Not enough good replicas to write`?** The primary has no replica in sync, e.g. while both replicas restart. It refuses writes to avoid losing them; set `replication.minReplicasToWrite: 0` to accept them anyway.

**Why do writes fail with `READONLY You can't write against a read only replica`?** The client wrote to a replica: through port 6379 of the Service with `architecture: replication`, or right after a failover. Connect through Sentinel and retry.

**How many queries run in parallel?** `THREAD_COUNT`, which defaults to the CPU limit, or to all of the node's cores without one (16 threads on a 16-core node in our test). Set it in `config` when pods share large nodes.

**Why does a pod log `this pod's volume is empty. Waiting for a pod with data to be promoted`?** The pod lost its data while it was the primary (or while all pods were down). Starting it as primary would make the replicas copy its empty dataset, so it waits until Sentinel promotes a pod that has the data (after `sentinel.downAfterMilliseconds`), then copies the data from it.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. Replaces `podAntiAffinityPreset`. |
| architecture | string | `"standalone"` | `standalone`: one FalkorDB instance. `replication`: one primary and replicas with Redis Sentinel, which promotes a replica when the primary fails. |
| auth.enabled | bool | `true` | Require a password (`requirepass`) for FalkorDB and Sentinel. Without it, anyone who can reach the pods can read and change every graph. |
| auth.existingSecret | string | `""` | Existing Secret with the password (recommended for production). |
| auth.existingSecretPasswordKey | string | `"password"` | Key in `existingSecret` with the password. |
| auth.password | string | `""` | Password. Generated when empty, and kept across upgrades. Ignored when `existingSecret` is set. |
| clusterDomain | string | `"cluster.local"` | Cluster DNS domain, used in the host names the pods announce to Sentinel and clients. |
| config | object | `{"MAX_QUEUED_QUERIES":25,"RESULTSET_SIZE":10000,"TIMEOUT":1000}` | FalkorDB module settings, passed as `FALKORDB_ARGS` (see FalkorDB's configuration reference). The defaults are those of the official image: queries waiting for a thread are limited to 25, read queries time out after 1 second and results are cut at 10000 rows. Set a key to `null` to drop it. `THREAD_COUNT` (default: the CPU limit, or all of the node's cores without one) limits concurrent queries. |
| durability.appendfsync | string | `"everysec"` | AOF fsync policy: `everysec`, `always` or `no`. |
| durability.appendonly | bool | `true` | Log every write to the append-only file (AOF), so a restart loses at most `appendfsync` worth of writes. |
| durability.save | string | `"3600 1 300 100 60 10000"` | RDB snapshot rules (`save`), e.g. `3600 1 300 100 60 10000` (Redis default). Empty string: no snapshots. |
| extraConfig | string | `""` | Extra lines for the FalkorDB (redis-server) configuration file, e.g. `maxclients 20000` or `aclfile /var/lib/falkordb/data/users.acl`. Added after the chart's settings, so they win. |
| extraEnv | list | `[]` | Extra environment variables of the FalkorDB container. |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of the FalkorDB container. |
| extraVolumes | list | `[]` | Extra volumes, e.g. CSV files for `LOAD CSV`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"falkordb/falkordb-server"` | Image repository. The official server image without the browser UI. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| metrics.enabled | bool | `false` | Add a Prometheus exporter (`redis_exporter`) next to every FalkorDB pod, on port 9121. |
| metrics.extraEnv | list | `[]` | Extra environment variables of the exporter, e.g. `REDIS_EXPORTER_CHECK_KEYS`. |
| metrics.image.pullPolicy | string | `"IfNotPresent"` | Exporter image pull policy. |
| metrics.image.repository | string | `"oliver006/redis_exporter"` | Exporter image repository. |
| metrics.image.tag | string | `"v1.93.0"` | Exporter image tag. |
| metrics.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources of the exporter container. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor (needs the monitoring.coreos.com CRDs). |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the label your Prometheus selects ServiceMonitors by. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes of the claims. |
| persistence.annotations | object | `{}` | Annotations for the claims. |
| persistence.enabled | bool | `true` | Create a PersistentVolumeClaim per pod for /var/lib/falkordb/data. If false, an `emptyDir` is used and the graphs are lost when the pod is deleted. |
| persistence.existingClaim | string | `""` | Use an existing claim instead (`standalone` only). |
| persistence.size | string | `"8Gi"` | Size of the claims. Leave room for the AOF and a full RDB snapshot next to each other. |
| persistence.storageClass | string | `""` | Storage class. Empty: the cluster default. |
| podAnnotations | object | `{}` | Pod annotations. |
| podAntiAffinityPreset | string | `"soft"` | Spread pods across nodes with `architecture: replication`: `soft` (preferred), `hard` (required) or `""` (off). Ignored when `affinity` is set. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget (`maxUnavailable: 1`) with `architecture: replication`. |
| podLabels | object | `{}` | Pod labels. |
| podSecurityContext | object | `{"fsGroup":999,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":999,"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. UID 999 is the image's `falkordb` user. |
| priorityClassName | string | `""` | Priority class name. |
| probes.liveness.failureThreshold | int | `6` | Liveness probe failures before the container is restarted. |
| probes.liveness.periodSeconds | int | `10` | Liveness probe period in seconds. |
| probes.readiness.failureThreshold | int | `3` | Readiness probe failures before the pod is taken out of the Service. |
| probes.readiness.periodSeconds | int | `5` | Readiness probe period in seconds. |
| probes.startup.failureThreshold | int | `360` | Startup probe failures before the container is restarted (5 s × 360 = 30 minutes for loading large graphs). |
| probes.startup.periodSeconds | int | `5` | Startup probe period in seconds. |
| replicaCount | int | `3` | Number of FalkorDB pods with `architecture: replication` (one primary, the rest replicas), each with its own Sentinel. At least 3, so the Sentinels keep a majority when a pod is gone. Ignored with `standalone`. |
| replication.minReplicasMaxLag | int | `10` | Seconds without a reply after which a replica no longer counts for `minReplicasToWrite`. |
| replication.minReplicasToWrite | int | `1` | With `architecture: replication`, the primary refuses writes (`NOREPLICAS`) unless this many replicas are connected and in sync. Stops a primary that was cut off or frozen from accepting writes that are lost when Sentinel demotes it. `0` turns it off. |
| resources | object | `{"limits":{"memory":"1Gi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources of the FalkorDB container. Graphs are held in memory; snapshots and AOF rewrites fork the process and need extra memory for pages that change meanwhile. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| sentinel.downAfterMilliseconds | int | `5000` | Milliseconds the primary must be unreachable before it counts as down. |
| sentinel.extraConfig | string | `""` | Extra lines for the Sentinel configuration file. |
| sentinel.failoverTimeout | int | `60000` | Failover timeout in milliseconds. |
| sentinel.masterSet | string | `"falkordb"` | Name of the monitored primary (`master` set). Sentinel-aware clients ask for it by this name. |
| sentinel.quorum | string | `""` | Sentinels that must agree the primary is down before a failover. Empty: a majority of `replicaCount`. |
| sentinel.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"20m","memory":"32Mi"}}` | Resources of the Sentinel container. |
| service.annotations | object | `{}` | Service annotations. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Empty: the full resource name. |
| terminationGracePeriodSeconds | int | `60` | Seconds to let FalkorDB hand over the primary role and save before it is killed. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints. |
