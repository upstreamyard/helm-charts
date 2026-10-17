# upstreamyard Helm charts

Helm charts maintained by [upstreamyard](https://github.com/upstreamyard), for our own container images and for projects' official images.

| Chart | App | Image |
|---|---|---|
| [`aegra`](charts/aegra) | [Aegra](https://github.com/aegra/aegra), a self-hosted alternative to LangGraph Platform | [`upstreamyard/aegra`](https://github.com/upstreamyard/aegra) |
| [`automq`](charts/automq) | [AutoMQ](https://github.com/AutoMQ/automq), Kafka-compatible streaming with messages stored in S3 (diskless Kafka) | [`automqinc/automq`](https://hub.docker.com/r/automqinc/automq) (official) |
| [`nemo-guardrails`](charts/nemo-guardrails) | [NVIDIA NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails), an OpenAI-compatible LLM guardrails server (jailbreak, content safety, PII and dialog rails) | [`upstreamyard/nemo-guardrails`](https://github.com/upstreamyard/nemo-guardrails) |
| [`saleor`](charts/saleor) | [Saleor](https://github.com/saleor/saleor), the headless GraphQL commerce platform, with its dashboard | official `ghcr.io/saleor/saleor` and `ghcr.io/saleor/saleor-dashboard` |

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
