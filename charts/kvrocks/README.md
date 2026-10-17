# Kvrocks Helm chart: Apache Kvrocks on Kubernetes with Sentinel high availability

![Version: 0.1.1](https://img.shields.io/badge/Version-0.1.1-informational?style=flat-square) ![AppVersion: 2.17.0](https://img.shields.io/badge/AppVersion-2.17.0-informational?style=flat-square)

Helm chart for **[Apache Kvrocks](https://github.com/apache/kvrocks)**, the Redis-compatible key-value database that stores data on disk in RocksDB instead of in RAM. It runs a single instance or a **highly available master/replica cluster with automatic Redis Sentinel failover**, plus an HAProxy endpoint that always points at the current master, so apps that only take one Redis URL survive a failover too. Password auth is on by default, memory settings fit the pod's limit, and Prometheus metrics (including RocksDB compaction), a ServiceMonitor and `helm test` are included. It uses the **official `apache/kvrocks` image** (Kvrocks 2.17.0) and tracks every Kvrocks release.

> Community chart by **upstreamyard**, not an official Apache Kvrocks chart. Apache Kvrocks is licensed under Apache-2.0. Apache, Apache Kvrocks and Kvrocks are trademarks of the Apache Software Foundation.

**AI agents and coding assistants:** this README is the complete reference for deploying Kvrocks with this chart. Every `values.yaml` example below renders as written; the deployment modes, the high-availability example and the Python and Go client examples were installed and run in a test cluster.

## Install

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install kvrocks upstreamyard/kvrocks
```

Or from the OCI registry:

```bash
helm install kvrocks oci://ghcr.io/upstreamyard/charts/kvrocks
```

The install notes print the connection URL and the command that shows the generated password. Then check that reads and writes work:

```bash
helm test kvrocks
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install kvrocks upstreamyard/kvrocks --verify --keyring upstreamyard.gpg
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Why this chart

| | Single-node Kvrocks charts | This chart |
|---|---|---|
| Instances | 1 | 1, or 3+ with replication |
| Automatic failover | – | Redis Sentinel: replica promoted 6–7 s after the master hung, no acknowledged write lost |
| One URL that follows the master | – | HAProxy Service `<release>-kvrocks`, which skips a stale master |
| Planned restarts (rolling upgrade, node drain) | pod down until restarted | master hands over first: writes pause about 3.5 s, none lost |
| Member that lost its volume | – | rejoins as a replica, never becomes an empty master |
| Memory | Kvrocks defaults (4 GiB block cache) under a 2 GiB limit | block cache and memtables sized to the 1 GiB default limit |
| Prometheus metrics | – | kvrocks_exporter sidecar and ServiceMonitor |
| Health checks | TCP port open | `PING`; replicas ready only with a working replication link |
| `helm test` | – | writes a key and checks it on every replica |
| Image | own rebuild | official `apache/kvrocks`, updated with every Kvrocks release |

## What the chart does

- **StatefulSet** with stable pod names (`<release>-kvrocks-0`, `-1`, …) and a PersistentVolumeClaim per pod for the RocksDB data.
- **Security:**
  - generated password in a Secret, kept across upgrades, or your own Secret (`auth.existingSecret`);
  - replicas, Sentinel, HAProxy and the exporter use the same password; Sentinel itself requires it too;
  - non-root (UID 999), read-only root filesystem, all capabilities dropped, no ServiceAccount token, `RuntimeDefault` seccomp profile. Tested in a namespace that enforces the `restricted` Pod Security Standard.
- **Sentinel mode:** each pod runs Kvrocks and a Sentinel sidecar ([Valkey](https://github.com/valkey-io/valkey)'s Sentinel, BSD-licensed). Sentinel promotes a replica when the master is down and reconfigures the others. Pods find each other through stable DNS names, so a restarted pod with a new IP rejoins without manual cleanup.
- **Safe restarts:**
  - a starting pod asks the running Sentinels who the master is and joins it;
  - Sentinel keeps the last known master on the data volume, so the whole cluster restarts with the right master;
  - a pod whose volume was lost waits until Sentinel has promoted a replica, then rejoins as a replica (see [Losing a volume](#losing-a-volume));
  - Sentinel keeps its ID and the replicas it knows across restarts, so it can fail over even when the master is gone while Sentinels restart.
- **Master handover on shutdown:** before a master pod stops, it pauses writes (`CLIENT PAUSE WRITE`, clients wait), asks Sentinel to promote a replica and steps down. Rolling upgrades and node drains pause writes for about 3.5 seconds and lose none.
- **Readiness:** a replica is ready once its replication link is up and no full sync is running, so a rolling update doesn't move on while a replica is still copying data.
- **Memory:** RocksDB's block cache (`kvrocks.blockCacheSize`, 256 MB) and memtables (`kvrocks.writeBufferSize`, 32 MB) are set for the default 1 GiB limit. Kvrocks' own defaults (4 GiB block cache, 64 MB memtables) need several GiB.
- **Metrics:** `metrics.enabled` adds [kvrocks_exporter](https://github.com/RocksLabs/kvrocks_exporter) on port 9121 with Kvrocks and RocksDB metrics; `metrics.serviceMonitor.enabled` adds a ServiceMonitor.
- **PodDisruptionBudgets** and soft anti-affinity for Kvrocks and HAProxy.

## Deployment modes

### Single instance (default)

One Kvrocks pod with its data on a PersistentVolumeClaim. If the pod or node fails, Kubernetes restarts it on the same volume.

```yaml
persistence:
  size: 50Gi
resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    memory: 2Gi
kvrocks:
  blockCacheSize: 768
```

### High availability with Sentinel

Three pods: one master and two replicas, with a Sentinel in each pod and two HAProxy pods in front.

```yaml
replicaCount: 3
sentinel:
  enabled: true
podAntiAffinityPreset: hard   # one pod per node
```

Tested in kind (3 members, a client writing through HAProxy 10 times a second, counting acknowledged writes against the final value):

| Event | Writes paused | Failed requests | Acknowledged writes lost |
|---|---|---|---|
| Master pod deleted (`kubectl delete pod`, handover) | 3.3–3.8 s | 2 | 0 |
| Master hung for 30 s, then resumed (`SIGSTOP`/`SIGCONT`) | 9.2–9.5 s | 36–42 | 0 |
| Rolling upgrade Kvrocks 2.16.0 → 2.17.0 (23 s) | 3.7 s | 8 | 0 |
| All nodes restarted at once (host reboot) | – | – | 0, same master as before |
| `helm uninstall` and reinstall on the kept volumes | – | – | 0, same master as before |

- Sentinel promotes a replica 6–7 seconds after the master stops answering (`sentinel.downAfterMilliseconds`: 5000).
- **Stale master protection:** a master that comes back after Sentinel replaced it still reports `role:master` for about 10 seconds. HAProxy only forwards to a master with a connected replica (`proxy.requireConnectedReplica`), so writes don't land on the stale master and get lost. Without this check, 47 acknowledged writes were lost in the same test.

- Replication is asynchronous, as in Redis: a write acknowledged in the last milliseconds before the master crashes can be lost. Our tests lost none, but they ran on one machine (kind); network partitions weren't tested.
- If both replicas are down, HAProxy refuses connections, because a lone master could be a stale one. Sentinel clients still reach the master. Set `proxy.requireConnectedReplica: false` to prefer availability.
- Use `replicaCount: 3` or 5. Sentinel needs a majority (`sentinel.quorum`, default 2 of 3) to agree on a failover.

### High availability without the proxy

Clients that support Redis Sentinel can ask Sentinel for the master directly; then HAProxy isn't needed:

```yaml
replicaCount: 3
sentinel:
  enabled: true
proxy:
  enabled: false
```

The `<release>-kvrocks` Service then doesn't exist. Use the Sentinel Service, see [Connecting clients](#connecting-clients).

## Connecting clients

The password is in the Secret `<release>-kvrocks` (key `password`; just `kvrocks` for a release named `kvrocks`):

```bash
kubectl get secret kvrocks -o jsonpath='{.data.password}' | base64 -d
```

**Single instance, or Sentinel mode with HAProxy:** any Redis client, one URL:

```
redis://:<password>@<release>-kvrocks.<namespace>.svc:6666
```

**Sentinel-aware clients:** Sentinel at `<release>-kvrocks-sentinel.<namespace>.svc:26379`, master set `kvrocks`, with the same password for Sentinel and Kvrocks. Examples:

```python
# Python (redis-py)
from redis.sentinel import Sentinel
s = Sentinel([("kvrocks-sentinel.default.svc", 26379)],
             sentinel_kwargs={"password": PASSWORD}, password=PASSWORD)
master = s.master_for("kvrocks")
master.set("key", "value")
```

```go
// Go (go-redis)
rdb := redis.NewFailoverClient(&redis.FailoverOptions{
	MasterName:       "kvrocks",
	SentinelAddrs:    []string{"kvrocks-sentinel.default.svc:26379"},
	SentinelPassword: password,
	Password:         password,
})
```

Sentinel returns the master as a pod DNS name (`<release>-kvrocks-N.<release>-kvrocks-headless.<namespace>.svc.cluster.local`), which resolves only inside the cluster.

**From your machine:** `kubectl port-forward svc/kvrocks 6666`, then `redis-cli -p 6666 -a <password>`.

## Sizing memory

Kvrocks keeps data on disk and uses memory for RocksDB's block cache, memtables and connections. Raise the cache with the memory limit:

| `resources.limits.memory` | `kvrocks.blockCacheSize` (MB) |
|---|---|
| 1Gi (default) | 256 (default) |
| 2Gi | 768 |
| 4Gi | 2048 |
| 8Gi | 4096 |

Tested: with the defaults (1 GiB limit, 256 MB block cache), Kvrocks used about 410 MiB of process memory while writing 670,000 and reading 165,000 keys per second with 3.1 GB of data on disk. The rest of the limit was page cache, which the kernel reclaims.

## Monitoring with Prometheus

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus   # the label your Prometheus selects ServiceMonitors by
```

The exporter serves `kvrocks_up`, `kvrocks_instance_info{role=...}`, `kvrocks_connected_slaves`, keyspace, command, memory and RocksDB metrics (`kvrocks_compaction_pending`, `kvrocks_estimate_pending_compaction_bytes`, …) on `/metrics`, port 9121.

## Losing a volume

When a replica's PersistentVolumeClaim is gone, the new pod copies all data from the master (full sync) and becomes ready when it's done.

When the **master's** volume is gone, Sentinel still names that pod master after it restarts. A plain Kvrocks start would make it an empty master, and the replicas would copy the empty database. The chart prevents that: if another member still has keys, the pod logs `Sentinel still names this member master, but its data volume is empty and other members have keys. Waiting for a failover to a replica.` and starts only after Sentinel has promoted a replica, as a replica of it. Tested: the pod waited 3–6 seconds, then copied all 1,000 keys from the new master. On a new cluster without keys it starts as master right away.

## Production example

```yaml
# values-prod.yaml
replicaCount: 3
sentinel:
  enabled: true
auth:
  existingSecret: kvrocks-auth     # key: password
persistence:
  size: 100Gi
  storageClass: fast-ssd
resources:
  requests:
    cpu: "1"
    memory: 4Gi
  limits:
    memory: 4Gi
kvrocks:
  blockCacheSize: 2048
  workers: 8
podAntiAffinityPreset: hard
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

## Your own configuration

- **Any `kvrocks.conf` setting:** `kvrocks.config`, e.g.

  ```yaml
  kvrocks:
    config:
      maxclients: 20000
      rocksdb.compression: zstd
      compact-cron: "0 3 * * *"
  ```

  The chart refuses the settings it manages itself: `bind`, `port`, `dir`, passwords and replication.
- **Files and secrets:** `extraVolumes` and `extraVolumeMounts`, e.g. TLS certificates for Kvrocks' `tls-*` settings.
- **Environment:** `extraEnv` and `extraEnvFrom`.

## FAQ

**Is there an official Kvrocks Helm chart?** The Apache Kvrocks project doesn't publish one. This chart is maintained by upstreamyard and uses Apache's official image.

**How do I run Kvrocks highly available on Kubernetes?** `replicaCount: 3` and `sentinel.enabled: true`. Clients connect to the HAProxy Service or ask Sentinel for the master. See [High availability with Sentinel](#high-availability-with-sentinel).

**Does Redis Sentinel work with Kvrocks?** Yes. Kvrocks supports the commands Sentinel uses (`INFO replication`, `SLAVEOF`, `CONFIG REWRITE`, `ROLE`), and this chart's tests promote replicas and turn old masters into replicas with Valkey's Sentinel.

**Kvrocks vs Redis or Valkey: which do I need?** Kvrocks speaks the Redis protocol but keeps data on disk in RocksDB, so a dataset much larger than RAM costs disk space, not memory. Redis and Valkey keep everything in memory and are faster per operation. Most Redis commands and clients work with Kvrocks; Kvrocks lists the [supported commands](https://kvrocks.apache.org/docs/supported-commands/).

**Can this replace the Bitnami Redis chart?** For apps that use Redis commands Kvrocks supports, yes: Sentinel mode works like Bitnami's `sentinel.enabled` with master set `kvrocks`, and the HAProxy Service gives a single URL. Kvrocks listens on port 6666, not 6379.

**How do I monitor Kvrocks with Prometheus?** `metrics.enabled=true` and `metrics.serviceMonitor.enabled=true`.

**Why `READONLY You can't write against a read only slave.`?** The client is connected to a replica. Connect to the `<release>-kvrocks` Service (HAProxy) or ask Sentinel for the master; don't use the headless Service or pod names for writes.

**Why `NOAUTH Authentication required`?** Auth is on by default. Use the password from the Secret, also for Sentinel (`sentinel_kwargs` in redis-py, `SentinelPassword` in go-redis).

**Why is my Kvrocks pod OOMKilled?** Usually the RocksDB block cache is larger than the memory limit, e.g. after setting `rocksdb.block_cache_size` to Kvrocks' default 4096 in a 1Gi pod. Keep `kvrocks.blockCacheSize` at about a quarter to half of `resources.limits.memory`.

**Does the chart support Kvrocks cluster mode?** Not yet. It runs one master with replicas; scale data size with disk, which Kvrocks handles far beyond RAM.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Custom affinity rules. Replaces `podAntiAffinityPreset`. |
| auth.enabled | bool | `true` | Require a password (`requirepass`). Replicas, Sentinel, the proxy and the exporter use the same password. |
| auth.existingSecret | string | `""` | Existing Secret with the password. |
| auth.existingSecretKey | string | `"password"` | Key of the password in `auth.existingSecret`. |
| auth.password | string | `""` | Password. Empty: a random one is generated on the first install and kept across upgrades. Ignored with `auth.existingSecret`. |
| clusterDomain | string | `"cluster.local"` | Kubernetes cluster DNS domain, used for the pod host names that replicas and Sentinel announce. |
| extraEnv | list | `[]` | Extra environment variables of the Kvrocks container. |
| extraEnvFrom | list | `[]` | Extra environment from ConfigMaps or Secrets for the Kvrocks container. |
| extraVolumeMounts | list | `[]` | Extra volume mounts of the Kvrocks container. |
| extraVolumes | list | `[]` | Extra volumes, e.g. TLS certificates. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"apache/kvrocks"` | Image repository. The chart uses the official Apache Kvrocks image. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| kvrocks.blockCacheSize | int | `256` | RocksDB block cache in MB (`rocksdb.block_cache_size`). Kvrocks' own default is 4096, more than the default memory limit. Keep it at about a quarter to half of the memory limit. |
| kvrocks.config | object | `{}` | Extra `kvrocks.conf` settings, as `name: value`, e.g. `maxclients: 20000` or `rocksdb.compression: zstd`. Settings the chart manages (bind, port, dir, passwords, replication) are refused. |
| kvrocks.workers | int | `4` | Worker threads (`workers`). |
| kvrocks.writeBufferSize | int | `32` | Memtable size in MB per column family (`rocksdb.write_buffer_size`). Kvrocks' own default is 64. |
| livenessProbe | object | `{"failureThreshold":6,"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe of Kvrocks (`PING`). |
| metrics.enabled | bool | `false` | Export Prometheus metrics with kvrocks_exporter (a sidecar per pod, port 9121), including RocksDB compaction and replication metrics. |
| metrics.image.pullPolicy | string | `"IfNotPresent"` | Pull policy. |
| metrics.image.repository | string | `"kvrocks/kvrocks-exporter"` | Exporter image. |
| metrics.image.tag | string | `"1.0.11"` | Exporter tag. |
| metrics.port | int | `9121` | Port of the Prometheus endpoint `/metrics`. |
| metrics.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources of the exporter. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra labels, e.g. the one your Prometheus selects on. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes of the volume. |
| persistence.annotations | object | `{}` | Annotations of the PersistentVolumeClaims. |
| persistence.enabled | bool | `true` | Store data on a PersistentVolumeClaim per pod. If false, an emptyDir is used and data is lost when a pod is deleted (testing only). |
| persistence.size | string | `"8Gi"` | Volume size per pod. |
| persistence.storageClass | string | `""` | Storage class. Empty uses the cluster default. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podAntiAffinityPreset | string | `"soft"` | Spread Kvrocks pods across nodes: `soft` (preferred), `hard` (required) or `none`. Ignored when `affinity` is set. |
| podDisruptionBudget.enabled | bool | `true` | Create PodDisruptionBudgets for Kvrocks (with Sentinel) and HAProxy (with more than one pod). |
| podDisruptionBudget.maxUnavailable | int | `1` | Kvrocks pods that may be down at once during voluntary disruptions such as node drains. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":999,"fsGroupChangePolicy":"OnRootMismatch","runAsGroup":999,"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The official image runs as UID 999. |
| port | int | `6666` | Port Kvrocks listens on. |
| priorityClassName | string | `""` | Priority class name. |
| proxy.enabled | bool | `true` | With `sentinel.enabled`: run HAProxy, which always forwards to the current master. Clients without Sentinel support connect to the `<release>-kvrocks` Service as to a single server. |
| proxy.image.pullPolicy | string | `"IfNotPresent"` | Pull policy. |
| proxy.image.repository | string | `"haproxy"` | HAProxy image. |
| proxy.image.tag | string | `"3.2.25-alpine"` | HAProxy tag. |
| proxy.nodeSelector | object | `{}` | Node selector of the HAProxy pods. |
| proxy.podAnnotations | object | `{}` | Pod annotations of the HAProxy pods. |
| proxy.replicaCount | int | `2` | HAProxy pods. |
| proxy.requireConnectedReplica | bool | `true` | Forward only to a master with at least one connected replica. Protects against writes to a stale master that comes back after a failover (they would be lost). If all replicas are down, the proxy refuses connections; Sentinel clients still reach the master. |
| proxy.resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Resources of the HAProxy pods. |
| proxy.timeoutClient | string | `"1h"` | Idle client timeout. Long, because Redis clients keep connections open (pub/sub, blocking commands). |
| proxy.tolerations | list | `[]` | Tolerations of the HAProxy pods. |
| readinessProbe | object | `{"failureThreshold":3,"periodSeconds":5,"timeoutSeconds":5}` | Readiness probe of Kvrocks. A replica is ready once its link to the master is up and no full sync is running. |
| replicaCount | int | `1` | Number of Kvrocks pods. `1` runs a single instance. With `sentinel.enabled`, 3 or more: one master and replicas, with automatic failover. |
| resources.limits.memory | string | `"1Gi"` | Memory limit. Kvrocks uses about `kvrocks.blockCacheSize` plus memtables plus a few hundred MB. |
| resources.requests.cpu | string | `"100m"` | CPU request. |
| resources.requests.memory | string | `"512Mi"` | Memory request. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context of all containers. |
| sentinel.downAfterMilliseconds | int | `5000` | Milliseconds without an answer before Sentinel considers the master down. |
| sentinel.enabled | bool | `false` | Run Redis Sentinel next to each Kvrocks pod for automatic failover. Needs `replicaCount` of 3 or more. |
| sentinel.failoverOnShutdown | bool | `true` | Hand the master role to a replica before a master pod stops (rolling updates, node drains), so writes pause for about 3.5 seconds instead of `downAfterMilliseconds` plus the election, and none are lost. |
| sentinel.failoverTimeout | int | `60000` | Failover timeout in milliseconds. |
| sentinel.image.pullPolicy | string | `"IfNotPresent"` | Pull policy. |
| sentinel.image.repository | string | `"valkey/valkey"` | Sentinel image. Valkey's Sentinel speaks the Redis Sentinel protocol (BSD licence). |
| sentinel.image.tag | string | `"9.0.6-alpine"` | Sentinel image tag. |
| sentinel.masterSet | string | `"kvrocks"` | Name of the master set that clients ask Sentinel for. |
| sentinel.parallelSyncs | int | `1` | Replicas that resync with a new master at the same time. |
| sentinel.port | int | `26379` | Sentinel port. |
| sentinel.quorum | string | `""` | Sentinels that must agree before a failover. Empty: a majority of `replicaCount`. |
| sentinel.resources | object | `{"limits":{"memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}}` | Resources of the Sentinel container. |
| service.annotations | object | `{}` | Annotations of the `<release>-kvrocks` Service. |
| service.type | string | `"ClusterIP"` | Type of the `<release>-kvrocks` Service (the write endpoint). |
| startupProbe | object | `{"failureThreshold":120,"periodSeconds":5}` | Startup probe of Kvrocks. Allows for opening a large database and for a member that waits for a failover before it rejoins (see "Losing a volume"). |
| terminationGracePeriodSeconds | int | `60` | Seconds Kubernetes waits after SIGTERM. Covers the master handover (`sentinel.failoverOnShutdown`). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[]` | Topology spread constraints, e.g. across zones. |
