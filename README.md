<img src="logo.png" alt="upstreamyard logo" width="120" align="right">

# upstreamyard Helm charts

> **Support:** For help with setup, production issues or custom changes, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm charts maintained by [upstreamyard](https://github.com/upstreamyard), for our own container images and for projects' official images.

| Chart | App | Image |
|---|---|---|
| [`activemq`](charts/activemq) | [Apache ActiveMQ Classic](https://github.com/apache/activemq) message broker (JMS, AMQP, STOMP, MQTT): single broker or high-availability master/slave, metrics | [`upstreamyard/activemq`](https://github.com/upstreamyard/activemq) |
| [`aegra`](charts/aegra) | [Aegra](https://github.com/aegra/aegra), a self-hosted alternative to LangGraph Platform | [`upstreamyard/aegra`](https://github.com/upstreamyard/aegra) |
| [`automq`](charts/automq) | [AutoMQ](https://github.com/AutoMQ/automq), Kafka-compatible streaming with messages stored in S3 (diskless Kafka) | [`automqinc/automq`](https://hub.docker.com/r/automqinc/automq) (official) |
| [`cube`](charts/cube) | [Cube](https://github.com/cube-js/cube), semantic layer and data API for BI and AI, with Cube Store | [`cubejs/cube`](https://hub.docker.com/r/cubejs/cube), [`cubejs/cubestore`](https://hub.docker.com/r/cubejs/cubestore) (official Cube images) |
| [`docling-serve`](charts/docling-serve) | [Docling Serve](https://github.com/docling-project/docling-serve), the Docling document conversion API (PDF, DOCX, PPTX to Markdown/JSON for RAG), with RQ workers and KEDA autoscaling | official [`ghcr.io/docling-project/docling-serve-cpu`](https://github.com/docling-project/docling-serve) and CUDA images |
| [`discourse`](charts/discourse) | [Discourse](https://github.com/discourse/discourse), the open-source community forum | [`upstreamyard/discourse`](https://github.com/upstreamyard/discourse) |
| [`dolt`](charts/dolt) | [Dolt](https://github.com/dolthub/dolt), the version-controlled MySQL-compatible SQL database, with primary/standby high availability | [`dolthub/dolt-sql-server`](https://hub.docker.com/r/dolthub/dolt-sql-server) (official) |
| [`electric`](charts/electric) | [Electric](https://github.com/electric-sql/electric), a sync engine that streams subsets of your PostgreSQL data to web and mobile apps in real time | [`electricsql/electric`](https://hub.docker.com/r/electricsql/electric) (official) |
| [`falkordb`](charts/falkordb) | [FalkorDB](https://github.com/FalkorDB/FalkorDB) graph database for knowledge graphs and GraphRAG, single instance or HA with Sentinel failover | official [`falkordb/falkordb-server`](https://hub.docker.com/r/falkordb/falkordb-server) |
| [`kvrocks`](charts/kvrocks) | [Apache Kvrocks](https://github.com/apache/kvrocks), Redis-compatible key-value database on RocksDB, with Sentinel high availability | [`apache/kvrocks`](https://hub.docker.com/r/apache/kvrocks) (official) |
| [`localai`](charts/localai) | [LocalAI](https://github.com/mudler/LocalAI), the self-hosted OpenAI-compatible API for LLMs, embeddings, images and speech on CPU or GPU: single server or distributed frontends and GPU workers, API key and admin account by default | official [`localai/localai`](https://hub.docker.com/r/localai/localai) (CPU and GPU variants) |
| [`logto`](charts/logto) | [Logto](https://github.com/logto-io/logto), identity and access management (OIDC, SSO) for apps and SaaS | [`svhd/logto`](https://hub.docker.com/r/svhd/logto) (official Logto image) |
| [`conductor`](charts/conductor) | [Conductor OSS](https://github.com/conductor-oss/conductor), a workflow orchestration engine originally built at Netflix | [`upstreamyard/conductor`](https://github.com/upstreamyard/conductor) |
| [`nemo-guardrails`](charts/nemo-guardrails) | [NVIDIA NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails), an OpenAI-compatible LLM guardrails server (jailbreak, content safety, PII and dialog rails) | [`upstreamyard/nemo-guardrails`](https://github.com/upstreamyard/nemo-guardrails) |
| [`parse-server`](charts/parse-server) | [Parse Server](https://github.com/parse-community/parse-server), the open-source backend for mobile, web and IoT apps | [`parseplatform/parse-server`](https://hub.docker.com/r/parseplatform/parse-server) (official) |
| [`saleor`](charts/saleor) | [Saleor](https://github.com/saleor/saleor), the headless GraphQL commerce platform, with its dashboard | official `ghcr.io/saleor/saleor` and `ghcr.io/saleor/saleor-dashboard` |
| [`plano`](charts/plano) | [Plano](https://github.com/katanemo/plano) AI gateway and LLM proxy: one OpenAI-compatible API for many providers, starts without internet access, non-root, API keys kept from the Envoy admin API, PostgreSQL state and Redis cache for several replicas, zero-downtime upgrades | official [`katanemo/plano`](https://hub.docker.com/r/katanemo/plano) |
| [`postal`](charts/postal) | [Postal](https://github.com/postalserver/postal), a mail delivery platform for sending and receiving email | official `ghcr.io/postalserver/postal` |
| [`shardingsphere-proxy`](charts/shardingsphere-proxy) | [Apache ShardingSphere-Proxy](https://github.com/apache/shardingsphere), a database proxy for sharding, read/write splitting, encryption and masking in front of MySQL and PostgreSQL | [`upstreamyard/shardingsphere-proxy`](https://github.com/upstreamyard/shardingsphere-proxy) |
| [`supertokens`](charts/supertokens) | [SuperTokens](https://github.com/supertokens/supertokens-core), the open-source authentication server (sessions, passwordless, social login, MFA) | [`supertokens/supertokens-postgresql`](https://hub.docker.com/r/supertokens/supertokens-postgresql) (official) |
| [`tigerbeetle`](charts/tigerbeetle) | [TigerBeetle](https://github.com/tigerbeetle/tigerbeetle) financial transactions database: fault-tolerant 3 or 6 replica cluster, safe replica recovery, rolling upgrades, Prometheus metrics | official [`ghcr.io/tigerbeetle/tigerbeetle`](https://github.com/tigerbeetle/tigerbeetle/pkgs/container/tigerbeetle) |
| [`xxl-job`](charts/xxl-job) | [XXL-JOB](https://github.com/xuxueli/xxl-job) admin, the distributed job scheduler for Java services | [`xuxueli/xxl-job-admin`](https://hub.docker.com/r/xuxueli/xxl-job-admin) (official XXL-JOB image) |

## Usage

```bash
helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm repo update
helm install aegra upstreamyard/aegra --set database.url='postgresql://user:password@host:5432/aegra'
```

Charts are also published as signed OCI artifacts:

```bash
helm install aegra oci://ghcr.io/upstreamyard/charts/aegra --set database.url='...'
cosign verify ghcr.io/upstreamyard/charts/aegra:<chart-version> \
  --certificate-identity-regexp '^https://github.com/upstreamyard/helm-charts/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## How releases work

1. **Daily** ([`bump.yml`](.github/workflows/bump.yml)): if a packaged project (listed per chart in [`.github/bump/`](.github/bump)) released a new version and the image for it is published, a bot opens a PR that updates `appVersion` and bumps the chart's patch version.
2. **On every PR** ([`lint-test.yml`](.github/workflows/lint-test.yml)): lint, README check, then a real install in a kind cluster against PostgreSQL (pgvector), Redis and the services the changed chart needs, with `helm test`.
3. Bot PRs **merge themselves** once `lint-test` passes. If it fails, the PR stays open for a human. PRs that also change files bundled with a chart (e.g. a database schema, via `scripts/bump-hooks/<chart>.sh`) always wait for a review.
4. **On merge to `main`** ([`release.yml`](.github/workflows/release.yml)): a GitHub Release, the `index.yaml` on GitHub Pages, the OCI chart on GHCR (cosign-signed) and Artifact Hub metadata. Artifact Hub re-scans the repository on its own.

## Contributing

Open a PR against `main`. Bump the chart `version` for every chart change, and regenerate the chart README with [helm-docs](https://github.com/norwoodj/helm-docs): `helm-docs --chart-search-root charts`.
