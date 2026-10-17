<img src="logo.png" alt="upstreamyard logo" width="120" align="right">

# upstreamyard Helm charts

Helm charts maintained by [upstreamyard](https://github.com/upstreamyard), for our own container images and for projects' official images.

| Chart | App | Image |
|---|---|---|
| [`activemq`](charts/activemq) | [Apache ActiveMQ Classic](https://github.com/apache/activemq) message broker (JMS, AMQP, STOMP, MQTT): single broker or high-availability master/slave, metrics | [`upstreamyard/activemq`](https://github.com/upstreamyard/activemq) |
| [`aegra`](charts/aegra) | [Aegra](https://github.com/aegra/aegra), a self-hosted alternative to LangGraph Platform | [`upstreamyard/aegra`](https://github.com/upstreamyard/aegra) |
| [`automq`](charts/automq) | [AutoMQ](https://github.com/AutoMQ/automq), Kafka-compatible streaming with messages stored in S3 (diskless Kafka) | [`automqinc/automq`](https://hub.docker.com/r/automqinc/automq) (official) |
| [`cube`](charts/cube) | [Cube](https://github.com/cube-js/cube), semantic layer and data API for BI and AI, with Cube Store | [`cubejs/cube`](https://hub.docker.com/r/cubejs/cube), [`cubejs/cubestore`](https://hub.docker.com/r/cubejs/cubestore) (official Cube images) |
| [`conductor`](charts/conductor) | [Conductor OSS](https://github.com/conductor-oss/conductor), a workflow orchestration engine originally built at Netflix | [`upstreamyard/conductor`](https://github.com/upstreamyard/conductor) |
| [`nemo-guardrails`](charts/nemo-guardrails) | [NVIDIA NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails), an OpenAI-compatible LLM guardrails server (jailbreak, content safety, PII and dialog rails) | [`upstreamyard/nemo-guardrails`](https://github.com/upstreamyard/nemo-guardrails) |
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
