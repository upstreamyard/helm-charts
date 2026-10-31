# AutoMQ Helm chart: diskless Kafka on S3 on Kubernetes

![Version: 0.1.3](https://img.shields.io/badge/Version-0.1.3-informational?style=flat-square) ![AppVersion: 1.7.4](https://img.shields.io/badge/AppVersion-1.7.4-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for **[AutoMQ](https://github.com/AutoMQ/automq)**, the open-source, Kafka-compatible streaming platform that stores messages in **S3 or S3-compatible object storage** instead of broker disks ("diskless Kafka"). Kafka clients, tools and protocols work unchanged. The chart runs **3 combined KRaft controller + broker nodes** by default, or separate controllers with **stateless broker-only nodes you can scale in seconds**. **SASL authentication is on by default** with generated passwords, and Prometheus metrics, a ServiceMonitor, PodDisruptionBudgets and `helm test` are included. It uses AutoMQ's official open-source image (`automqinc/automq`, AutoMQ 1.7.4, based on Kafka 3.9) and replaces the Bitnami Kafka chart setup that AutoMQ's own guide relies on.

> Community chart by **upstreamyard**, not an official AutoMQ chart. AutoMQ is licensed under Apache-2.0. Apache Kafka and Kafka are trademarks of the Apache Software Foundation.

**AI agents and coding assistants:** this README is the complete reference for the chart. Required: an S3 bucket (`s3.dataBucket`) and credentials (`s3.accessKey`/`s3.secretKey`, `s3.existingSecret`, or `s3.authType: instance`). Clients connect to the bootstrap address from the install notes, with SASL/PLAIN unless `auth.enabled=false`.

## Install

AutoMQ needs an S3 bucket. Create one, then:

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install automq upstreamyard/automq \
  --set s3.dataBucket=my-automq-bucket \
  --set s3.region=eu-central-1 \
  --set s3.existingSecret=automq-s3        # keys: access-key, secret-key
```

Or from the OCI registry:

```bash
helm install automq oci://ghcr.io/upstreamyard/charts/automq -f values.yaml
```

The install notes show the bootstrap address, the client properties and the command that prints the generated password. Then check that messages flow:

```bash
helm test automq
```

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install automq upstreamyard/automq --verify --keyring upstreamyard.gpg -f values.yaml
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## What the chart does

- **Controllers:** a StatefulSet (`<release>-automq-controller-0..2`) with a small volume each for the KRaft metadata log. By default they are also brokers.
- **Broker-only nodes:** an optional second StatefulSet (`<release>-automq-broker-*`, node IDs from 1000). Messages and the write-ahead log live in S3, so brokers need no volume.
- **AutoMQ's storage engine is always on.** The image's `-kafka` variant otherwise starts as plain Kafka and fails on the first message (`ClassCastException ... ElasticUnifiedLog`); the chart sets `elasticstream.enable` and AutoMQ's self-balancing reporter for you.
- **Security:**
  - SASL/PLAIN on all listeners (clients, brokers, controllers), with generated passwords kept across upgrades;
  - non-root (UID 1000), read-only root filesystem, all capabilities dropped, no ServiceAccount token.
- **Self-balancing:** AutoMQ moves partitions between brokers by itself, e.g. after scaling.
- **Graceful shutdown:** a node hands its partitions to other brokers on `SIGTERM`. A broker stopped in 4 seconds and was ready again 10 seconds after deletion in our test.
- **Metrics:** AutoMQ's built-in Prometheus exporter on port 9090 (broker, controller, S3 stream and JVM metrics); `metrics.serviceMonitor.enabled` adds a ServiceMonitor.
- **Stable cluster ID:** derived from the namespace and release name, so it never changes on upgrades, with `helm template` or with GitOps tools.

## Deployment modes

### Three combined nodes (default)

Three nodes that are KRaft controllers and brokers at once. Good for most clusters up to moderate throughput.

```yaml
s3:
  dataBucket: my-automq-bucket
  region: eu-central-1
  existingSecret: automq-s3
```

- **Tested in kind:** a rolling upgrade from AutoMQ 1.7.3 to 1.7.4 under load (100 messages/s, `acks=all`) delivered 30,000 of 30,000 messages; the slowest message took 5.5 s. Deleting a node and force-killing another one under load delivered 18,000 of 18,000.
- The PodDisruptionBudget allows one node down at a time, which keeps the quorum.

### Controllers plus scalable brokers

Three controller-only nodes and any number of broker-only nodes. Scale throughput with `broker.replicas` without touching the quorum.

```yaml
controller:
  controllerOnly: true
broker:
  replicas: 3
```

- **Tested in kind:** scaling brokers from 3 to 1 took 14 seconds; all 6 partitions moved to the remaining broker and all 3,000 messages stayed readable. Scaling back to 3 reused the node IDs.
- After **permanently** removing brokers, their registrations stay as "fenced" (`kafka_broker_fenced_count`), as in Apache Kafka. Remove them with `kafka-cluster.sh unregister --bootstrap-server <bootstrap> --id <node id>` (tested).

### Single node

For development and tests only: no redundancy for the metadata.

```yaml
controller:
  replicas: 1
```

## S3 storage

| Setting | AWS S3 | S3-compatible (MinIO, Ceph, R2, ...) |
|---|---|---|
| `s3.dataBucket` | your bucket | your bucket |
| `s3.region` | bucket region | any value the store accepts, e.g. `us-east-1` |
| `s3.endpoint` | empty | `http://minio.storage.svc:9000` |
| `s3.pathStyle` | `false` | usually `true` |

- **Credentials:** `s3.existingSecret` (keys `access-key` and `secret-key`, renamable), `s3.accessKey`/`s3.secretKey` (stored in the chart's Secret), or `s3.authType: instance`. With `instance`, AutoMQ uses the AWS SDK's default chain: IRSA (annotate the ServiceAccount and set `serviceAccount.automountToken: true`), EKS Pod Identity or the node's instance profile.
- **Tested** with a MinIO-compatible store (pgsty/silo) only. AWS S3, IRSA and other providers were not tested.
- **The write-ahead log is in S3 as well** (AutoMQ's S3 WAL). Expect produce latencies of a few hundred milliseconds: 330 ms median and 450 ms p95 in our test.
- **Several clusters can share a bucket:** AutoMQ prefixes every object with the cluster ID (`.../_kafka_<cluster id>/...`).
- **Deleting a cluster** leaves its objects in the bucket. Empty the bucket (or the cluster's prefix) yourself when you remove a cluster for good.
- `s3.opsBucket` holds AutoMQ's operational uploads (logs, metrics) and defaults to the data bucket. Nothing was written there during our tests, which ran a few minutes each.

## Connecting clients

- **Bootstrap address:** `<name>.<namespace>.svc.cluster.local:9092`, where `<name>` is `<release>-automq`, or just the release name if it contains "automq". For `helm install automq ...` in namespace `streaming` that is `automq.streaming.svc.cluster.local:9092`. Clients then connect to each broker by its own name, e.g. `automq-controller-0.automq-headless.streaming.svc.cluster.local:9092`. The install notes print the exact address.
- **Client properties** (with `auth.enabled=true`, the default):

  ```properties
  security.protocol=SASL_PLAINTEXT
  sasl.mechanism=PLAIN
  sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="user1" password="<password>";
  ```

  The password is in the chart's Secret under `user-<name>`; the install notes print the command.
- **Users:** list them in `auth.users`. Every user may do everything (no ACLs). `auth.interBrokerUser` is the internal login between nodes.
- **Only in-cluster access** in this version: brokers advertise their in-cluster DNS names, and there is no TLS. Keep the traffic inside the cluster network.

## Upgrades and password changes

- **AutoMQ versions:** set `image.tag` (e.g. `1.7.4-kafka`) or upgrade the chart. Nodes restart one by one; 1.7.3 to 1.7.4 was tested under load (see above).
- **Changing `auth.interBrokerPassword`:** a normal rolling update stalls, because old and new nodes reject each other's password. Run `helm upgrade`, then restart all nodes at once:

  ```bash
  kubectl delete pod -l app.kubernetes.io/instance=<release>,app.kubernetes.io/name=automq
  ```

  In our test the cluster was back after about 2 minutes and `helm test` passed. Plan this as downtime.
- **Reinstalling** under the same name and namespace keeps the cluster ID. With the controller volumes still there (Helm doesn't delete them), all topics and messages came back in our test. Wait until the old pods are gone first; otherwise the StatefulSet may not recreate a pod whose old copy is still terminating (a Kubernetes behaviour).
- **Generated passwords change on reinstall**, because `helm uninstall` deletes the Secret. Use `auth.existingSecret` when clients must keep their passwords.

## Production example

```yaml
# values-prod.yaml
s3:
  dataBucket: my-automq-bucket
  region: eu-central-1
  authType: instance                 # IRSA
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/automq
  automountToken: true
auth:
  existingSecret: automq-auth        # keys: inter-broker-password, orders-service, billing
  users:
    - name: orders-service
    - name: billing
controller:
  controllerOnly: true
  heapOpts: "-Xms2g -Xmx2g -XX:MetaspaceSize=96m -XX:MaxDirectMemorySize=2g"
  resources:
    requests: { cpu: "1", memory: 6Gi }
    limits: { memory: 6Gi }
  podAntiAffinityPreset: hard
broker:
  replicas: 3
  heapOpts: "-Xms4g -Xmx4g -XX:MetaspaceSize=96m -XX:MaxDirectMemorySize=6g"
  resources:
    requests: { cpu: "4", memory: 14Gi }
    limits: { memory: 14Gi }
  podAntiAffinityPreset: hard
metrics:
  serviceMonitor:
    enabled: true
```

## Your own configuration

- **Server properties:** `config` takes any Kafka or AutoMQ server property, e.g. `num.partitions: 6` or `log.retention.hours: 72` (tested with `num.partitions`). They override the chart's settings, so `config` can also replace the S3 URLs completely (`s3.data.buckets`, `s3.ops.buckets`, `s3.wal.path`). The chart turns them into the image's environment variables (`.` becomes `_`, `_` becomes `__`, `-` becomes `___`).
- **Not configurable through `config`:** node IDs, advertised listeners and the SASL logins, which the start script sets per pod.
- **Everything else:** `extraEnv`, `extraEnvFrom`, `extraVolumes` and `extraVolumeMounts`.

## Known issues

- **Controller count is fixed** after the first install: the chart uses a static KRaft quorum (`controller.quorum.voters`).
- **No TLS and no external access** yet (see [Connecting clients](#connecting-clients)).
- Node failure was not tested, because the test cluster had a single node. Pod deletion and force-killing were tested.
- The Kafka console consumer without credentials doesn't fail fast against a SASL listener; it retries until its timeout, as with Apache Kafka.

## FAQ

**Is there an official AutoMQ Helm chart?** AutoMQ publishes a Helm chart for its commercial AutoMQ Enterprise edition only (as of October 2026). For the open-source edition, AutoMQ's guide uses the Bitnami Kafka chart with an AutoMQ image. This chart is a dedicated, maintained chart for the open-source edition.

**What replaces the Bitnami Kafka chart for AutoMQ?** This chart. Bitnami's Kafka images are no longer freely maintained, and the Bitnami route needs `global.security.allowInsecureImages` plus AutoMQ's `-bitnami` image.

**Is AutoMQ compatible with Kafka clients?** AutoMQ 1.7 is based on Apache Kafka 3.9.1 and speaks the Kafka protocol. We tested the Kafka CLI tools (topics, console producer and consumer, producer perf test, metadata quorum, cluster unregister); `helm test` uses them too. Other clients were not tested here.

**Why are there no replicas per partition?** Durability comes from S3, so AutoMQ keeps one copy per partition (`ReplicationFactor: 1`) and moves partitions between brokers instead of copying data.

**How do I run AutoMQ highly available on Kubernetes?** The default (3 combined nodes) or `controller.controllerOnly: true` with `broker.replicas >= 2`. Spread the pods with `podAntiAffinityPreset: hard`.

**How do I monitor AutoMQ with Prometheus?** Metrics are on by default (port 9090). Set `metrics.serviceMonitor.enabled=true` for the Prometheus Operator.

**Why is produce latency higher than with Kafka on local disks?** The open-source edition writes its write-ahead log to S3, so each acknowledged write waits for S3 (330 ms median in our test).

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| auth.enabled | bool | `true` | Require SASL/PLAIN authentication on all listeners (clients, brokers and controllers). Passwords travel unencrypted without TLS, so keep the cluster network private. |
| auth.existingSecret | string | `""` | Existing Secret with the passwords: key `inter-broker-password` plus one key per user, named like the user. Passwords must not contain `"` or `\`. |
| auth.interBrokerPassword | string | `""` | Password of `interBrokerUser`. Generated once and kept across upgrades when empty. |
| auth.interBrokerUser | string | `"inter_broker"` | Username brokers and controllers use among themselves. It can also be used as an admin login. |
| auth.users | list | `[{"name":"user1","password":""}]` | Users that clients log in with. A password left empty is generated once and kept across upgrades. Names may use letters, digits, `.`, `_` and `-`. |
| broker.affinity | object | `{}` | Affinity. When empty, `podAntiAffinityPreset` applies. |
| broker.heapOpts | string | `"-Xms1g -Xmx1g -XX:MetaspaceSize=96m -XX:MaxDirectMemorySize=1g"` | JVM heap and direct memory. |
| broker.nodeSelector | object | `{}` | Node selector. |
| broker.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| broker.persistence.annotations | object | `{}` | Annotations for the PersistentVolumeClaims. |
| broker.persistence.enabled | bool | `false` | Use a PersistentVolumeClaim for the broker's local metadata cache. Off by default: brokers rebuild it from the controllers. |
| broker.persistence.size | string | `"5Gi"` | Volume size. |
| broker.persistence.storageClass | string | `""` | Storage class (empty = cluster default). |
| broker.podAnnotations | object | `{}` | Extra pod annotations. |
| broker.podAntiAffinityPreset | string | `"soft"` | Spread pods across nodes: `soft`, `hard` or empty for none. |
| broker.podLabels | object | `{}` | Extra pod labels. |
| broker.replicas | int | `0` | Number of broker-only nodes. They store nothing locally that matters, so you can scale them up and down. |
| broker.resources | object | `{"limits":{"memory":"3Gi"},"requests":{"cpu":"500m","memory":"3Gi"}}` | Container resources. |
| broker.tolerations | list | `[]` | Tolerations. |
| broker.topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| clusterDomain | string | `"cluster.local"` | Cluster DNS domain, used in the addresses brokers advertise to clients. |
| clusterId | string | `""` | KRaft cluster ID (22 characters, base64url). Defaults to a stable value derived from the release namespace and name. It must never change after the first install. |
| config | object | `{}` | Extra Kafka/AutoMQ server properties for all nodes, e.g. `num.partitions: 6`. They override the chart's settings. |
| controller.affinity | object | `{}` | Affinity. When empty, `podAntiAffinityPreset` applies. |
| controller.controllerOnly | bool | `false` | Run controllers as controllers only. `false` makes them combined controller + broker nodes; `true` needs `broker.replicas >= 1`. |
| controller.heapOpts | string | `"-Xms1g -Xmx1g -XX:MetaspaceSize=96m -XX:MaxDirectMemorySize=1g"` | JVM heap and direct memory. AutoMQ uses direct memory for its write-ahead log and block cache. |
| controller.nodeSelector | object | `{}` | Node selector. |
| controller.persistence.accessModes | list | `["ReadWriteOnce"]` | Access modes. |
| controller.persistence.annotations | object | `{}` | Annotations for the PersistentVolumeClaims. |
| controller.persistence.enabled | bool | `true` | Keep the KRaft metadata log on a PersistentVolumeClaim. Controllers lose the cluster metadata without it. |
| controller.persistence.size | string | `"10Gi"` | Volume size. Only cluster metadata is stored locally; messages live in S3. |
| controller.persistence.storageClass | string | `""` | Storage class (empty = cluster default). |
| controller.podAnnotations | object | `{}` | Extra pod annotations. |
| controller.podAntiAffinityPreset | string | `"soft"` | Spread pods across nodes: `soft`, `hard` or empty for none. |
| controller.podLabels | object | `{}` | Extra pod labels. |
| controller.replicas | int | `3` | Number of controller nodes (KRaft quorum voters): 1, 3 or 5. Fixed after the first install. |
| controller.resources | object | `{"limits":{"memory":"3Gi"},"requests":{"cpu":"500m","memory":"3Gi"}}` | Container resources. |
| controller.tolerations | list | `[]` | Tolerations. |
| controller.topologySpreadConstraints | list | `[]` | Topology spread constraints. |
| extraEnv | list | `[]` | Extra environment variables for all nodes. |
| extraEnvFrom | list | `[]` | Extra `envFrom` sources for all nodes. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for all nodes. |
| extraVolumes | list | `[]` | Extra volumes for all nodes. |
| fullnameOverride | string | `""` | Override the full resource name prefix. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"automqinc/automq"` | Image repository. The chart uses the `-kafka` variant of AutoMQ's official image (non-root, configured by environment variables). |
| image.tag | string | `""` | Image tag. Defaults to `<appVersion>-kafka`. |
| imagePullSecrets | list | `[]` | Pull secrets for private registries or mirrors. |
| metrics.enabled | bool | `true` | Expose Prometheus metrics (AutoMQ's built-in exporter) on port 9090. |
| metrics.serviceMonitor.enabled | bool | `false` | Create a Prometheus Operator ServiceMonitor. |
| metrics.serviceMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.serviceMonitor.labels | object | `{}` | Extra ServiceMonitor labels (e.g. for your Prometheus' selector). |
| nameOverride | string | `""` | Override the chart name. |
| podDisruptionBudget.enabled | bool | `true` | Create a PodDisruptionBudget per node group (maxUnavailable 1). |
| podSecurityContext | object | `{"fsGroup":1000,"runAsGroup":1000,"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| priorityClassName | string | `""` | Priority class for all pods. |
| probes.liveness.failureThreshold | int | `6` | Failed checks before the pod restarts. |
| probes.liveness.periodSeconds | int | `10` | Seconds between liveness checks. |
| probes.readiness.failureThreshold | int | `3` | Failed checks before the pod stops receiving traffic. |
| probes.readiness.periodSeconds | int | `5` | Seconds between readiness checks. |
| probes.startup.failureThreshold | int | `60` | Failed checks before the pod restarts (5 s x 60 = 5 minutes to start). |
| probes.startup.periodSeconds | int | `5` | Seconds between startup checks. |
| s3.accessKey | string | `""` | Access key ID (`authType: static`). Ignored when `existingSecret` is set. |
| s3.authType | string | `"static"` | How AutoMQ authenticates to S3: `static` (access key from a Secret) or `instance` (no keys; the AWS SDK's default chain finds IRSA, EKS Pod Identity or the node's instance profile). |
| s3.dataBucket | string | `""` | Bucket for message data and the write-ahead log (required unless `config` sets `s3.data.buckets`). |
| s3.endpoint | string | `""` | S3 API endpoint. Leave empty for AWS S3; set it for MinIO, Ceph, Cloudflare R2, GCS and other S3-compatible storage. |
| s3.existingSecret | string | `""` | Existing Secret with the S3 credentials (`authType: static`). |
| s3.existingSecretAccessKeyKey | string | `"access-key"` | Key of the access key ID in `existingSecret`. |
| s3.existingSecretSecretKeyKey | string | `"secret-key"` | Key of the secret access key in `existingSecret`. |
| s3.opsBucket | string | `""` | Bucket for AutoMQ's operational data (logs and metrics it uploads). Defaults to `dataBucket`. |
| s3.pathStyle | bool | `false` | Use path-style URLs (`endpoint/bucket`). Most self-hosted S3-compatible stores need `true`. |
| s3.region | string | `"us-east-1"` | Bucket region. |
| s3.secretKey | string | `""` | Secret access key (`authType: static`). Ignored when `existingSecret` is set. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. |
| service.annotations | object | `{}` | Annotations for the client Service. |
| service.port | int | `9092` | Port of the client Service. |
| service.type | string | `"ClusterIP"` | Type of the client Service. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations, e.g. `eks.amazonaws.com/role-arn` for `s3.authType: instance`. |
| serviceAccount.automountToken | bool | `false` | Mount the ServiceAccount token. Needed for IRSA and similar pod identities. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name (generated when empty). |
| terminationGracePeriodSeconds | int | `120` | Seconds a node gets to shut down. AutoMQ moves its partitions to other brokers first. |
