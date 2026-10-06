# upstreamyard Helm charts

Helm charts for the container images maintained by [upstreamyard](https://github.com/upstreamyard).

| Chart | App | Image |
|---|---|---|
| [`aegra`](charts/aegra) | [Aegra](https://github.com/aegra/aegra), a self-hosted alternative to LangGraph Platform | [`upstreamyard/aegra`](https://github.com/upstreamyard/aegra) |

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

1. **Daily** ([`bump.yml`](.github/workflows/bump.yml)): if an upstream project released a new version and our image for it is published, a bot opens a PR that updates `appVersion` and bumps the chart's patch version.
2. **On every PR** ([`lint-test.yml`](.github/workflows/lint-test.yml)): lint, README check, then a real install in a kind cluster against PostgreSQL (pgvector) and Redis, with `helm test`.
3. Bot PRs **merge themselves** once `lint-test` passes. If it fails, the PR stays open for a human.
4. **On merge to `main`** ([`release.yml`](.github/workflows/release.yml)): a GitHub Release, the `index.yaml` on GitHub Pages, the OCI chart on GHCR (cosign-signed) and Artifact Hub metadata. Artifact Hub re-scans the repository on its own.

## One-time setup (maintainers)

- An empty `gh-pages` branch, with GitHub Pages serving from it.
- Settings → General: enable **Allow auto-merge**.
- A ruleset on `main`: require a pull request and the status check `lint-test`.
- Secret `CHARTS_BOT_TOKEN`: a GitHub App or fine-grained PAT with contents and pull requests write on this repo.
- After the first release, set the GHCR package `charts/aegra` to public.
- Artifact Hub: register `https://upstreamyard.github.io/helm-charts` as a Helm repository under the `upstreamyard` organization, then put the repository ID into [`artifacthub-repo.yml`](artifacthub-repo.yml).

## Contributing

Open a PR against `main`. Bump the chart `version` for every chart change, and regenerate the chart README with [helm-docs](https://github.com/norwoodj/helm-docs): `helm-docs --chart-search-root charts`.
