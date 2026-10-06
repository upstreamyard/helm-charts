# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or installing its charts.

## Installing a chart

- Repository: `helm repo add upstreamyard https://upstreamyard.github.io/helm-charts`, or OCI `oci://ghcr.io/upstreamyard/charts/<chart>`.
- Every chart documents all of its values in `charts/<chart>/README.md`, and `values.schema.json` validates them.
- `aegra`: requires PostgreSQL with pgvector (`database.url` or `database.existingSecret`). More than 1 replica requires Redis (`redis.url` or `redis.existingSecret`). Own agents and authentication ship in a user image built `FROM upstreamyard/aegra` (files under `/app`, `AEGRA_CONFIG=/app/agents/aegra.json`), set via `image.repository`. Auth is on only if that `aegra.json` has an `"auth"` entry; `AUTH_TYPE` has no effect in Aegra 0.10.8. Verify with `helm test <release>`.

## Working on this repository

Layout:

- `charts/<chart>/`: one chart per image published by `upstreamyard/<image>`
- `charts/<chart>/ci/*-values.yaml`: values used by `ct install` in CI
- `.github/ci/deps.yaml`: throwaway PostgreSQL (pgvector) and Redis for CI, reachable at `*.deps.svc`
- `scripts/bump-chart.sh`: version bump logic used by `bump.yml`, which can run locally with `DRY_RUN=1`

Rules:

- Never push to `main`. Create a branch and open a pull request into `main`.
- Bump the chart `version` on every change to a chart; CI enforces this.
- Regenerate chart READMEs after changing `values.yaml` or `README.md.gotmpl`: `helm-docs --chart-search-root charts`. Write a `# --` comment above every value.
- Follow the upstream project's documentation for deployment behaviour (probes, migrations, required services), and link to it rather than restating it.
- Charts never bundle databases or other stateful services; users bring their own.

Checks before opening a PR:

```bash
ct lint --config ct.yaml
helm template t charts/aegra -f charts/aegra/ci/multi-replica-values.yaml | kubeconform -strict -summary
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
```
