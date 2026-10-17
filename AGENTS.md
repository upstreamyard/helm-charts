# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or installing its charts.

## Installing a chart

- Repository: `helm repo add upstreamyard https://upstreamyard.github.io/helm-charts`, or OCI `oci://ghcr.io/upstreamyard/charts/<chart>`.
- Every chart documents all of its values in `charts/<chart>/README.md`, and `values.schema.json` validates them.
- `aegra`: requires PostgreSQL with pgvector (`database.url` or `database.existingSecret`). More than 1 replica requires Redis (`redis.url` or `redis.existingSecret`). Own agents and authentication ship in a user image built `FROM upstreamyard/aegra` (files under `/app`, `AEGRA_CONFIG=/app/agents/aegra.json`), set via `image.repository`. Auth is on only if that `aegra.json` has an `"auth"` entry; `AUTH_TYPE` has no effect in Aegra 0.10.8. Verify with `helm test <release>`.
- `automq`: requires an S3 bucket (`s3.dataBucket`; plus `s3.endpoint` and `s3.pathStyle: true` for S3-compatible stores) and credentials (`s3.accessKey`/`s3.secretKey`, `s3.existingSecret`, or `s3.authType: instance` for IRSA/Pod Identity). SASL/PLAIN is on by default; passwords are in the chart's Secret as `user-<name>`. `controller.replicas` (1, 3 or 5) is fixed after install; scale with `broker.replicas` and `controller.controllerOnly: true`. Clients use the bootstrap address from the install notes. Verify with `helm test <release>`.
- `falkordb`: runs FalkorDB's official `falkordb/falkordb-server` image. `architecture: standalone` (default) or `replication` (`replicaCount` >= 3, Redis Sentinel failover). With replication, clients connect to Sentinel on port 26379 of the Service with primary name `falkordb` and the same password; port 6379 of the Service reaches any pod and is for read-only queries. Password generated in the Secret `<release>-falkordb` (key `password`) unless `auth.existingSecret` is set. Module settings go in `config` (the image's 1-second read `TIMEOUT` is the default). Verify with `helm test <release>`.

## Working on this repository

Layout:

- `charts/<chart>/`: one chart per packaged project, using our `upstreamyard/<image>` or the project's official image
- `charts/<chart>/ci/*-values.yaml`: values used by `ct install` in CI
- `.github/bump/<chart>.yaml`: the releases and images a chart follows (`project`, `image`, optional `tag_prefix`, `tag_suffix`, `release_prefix`, `values_path`), read by `bump.yml`
- `.github/ci/deps/shared.yaml`: throwaway PostgreSQL (pgvector, logical replication on) and Redis for CI, reachable at `*.deps.svc`
- `.github/ci/deps/<chart>.yaml`: test services only that chart needs; CI starts them when the chart changes
- `scripts/bump-chart.sh`: version bump logic used by `bump.yml`, which can run locally with `DRY_RUN=1`
- `scripts/bump-hooks/<chart>.sh`: optional per-chart step of a bump (e.g. refreshing a bundled database schema); bump PRs that change `charts/<chart>/files` don't merge themselves

Rules:

- Never push to `main`. Create a branch and open a pull request into `main`.
- Bump the chart `version` on every change to a chart; CI enforces this.
- Regenerate chart READMEs after changing `values.yaml` or `README.md.gotmpl`: `helm-docs --chart-search-root charts`. Write a `# --` comment above every value.
- Follow the app's own project documentation for deployment behaviour (probes, migrations, required services), and link to it rather than restating it.
- Charts never bundle databases or other stateful services; users bring their own.
- A new chart adds its own `.github/bump/<chart>.yaml` (and `.github/ci/deps/<chart>.yaml` if CI needs extra services), a row in the `README.md` table and a line under "Installing a chart" here.

Checks before opening a PR:

```bash
ct lint --config ct.yaml
helm template t charts/aegra -f charts/aegra/ci/multi-replica-values.yaml | kubeconform -strict -summary
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
```
