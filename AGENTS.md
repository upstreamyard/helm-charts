# AGENTS.md

Instructions for AI agents and coding assistants working with this repository or installing its charts.

## Installing a chart

- Repository: `helm repo add upstreamyard https://upstreamyard.github.io/helm-charts`, or OCI `oci://ghcr.io/upstreamyard/charts/<chart>`.
- Every chart documents all of its values in `charts/<chart>/README.md`, and `values.schema.json` validates them.
- `aegra`: requires PostgreSQL with pgvector (`database.url` or `database.existingSecret`). More than 1 replica requires Redis (`redis.url` or `redis.existingSecret`). Own agents and authentication ship in a user image built `FROM upstreamyard/aegra` (files under `/app`, `AEGRA_CONFIG=/app/agents/aegra.json`), set via `image.repository`. Auth is on only if that `aegra.json` has an `"auth"` entry; `AUTH_TYPE` has no effect in Aegra 0.10.8. Verify with `helm test <release>`.
- `automq`: requires an S3 bucket (`s3.dataBucket`; plus `s3.endpoint` and `s3.pathStyle: true` for S3-compatible stores) and credentials (`s3.accessKey`/`s3.secretKey`, `s3.existingSecret`, or `s3.authType: instance` for IRSA/Pod Identity). SASL/PLAIN is on by default; passwords are in the chart's Secret as `user-<name>`. `controller.replicas` (1, 3 or 5) is fixed after install; scale with `broker.replicas` and `controller.controllerOnly: true`. Clients use the bootstrap address from the install notes. Verify with `helm test <release>`.
- `cube`: uses the official images `cubejs/cube` and `cubejs/cubestore` (tags `v<version>`). Requires `apiSecret`, `datasource.type` (plus connection settings or driver variables in `extraEnv`), a data model (`model.files` or `model.existingConfigMap`), and shared storage for Cube Store (`cubestore.storage.type`: `s3`, `gcs`, `minio` with a non-empty `subPath`, or `sharedVolume`). Cube Store has no multi-arch images: set `cubestore.image.variant: arm64v8` on arm64. Every API request needs a JWT signed with the API secret. Verify with `helm test <release>`.
- `electric`: requires PostgreSQL 14+ with `wal_level=logical` (`database.url` or `database.existingSecret`), connecting directly (no pooler) as a role with `REPLICATION`, `CREATE` on the database and ownership of the synced tables. Requires `electric.secret` or `electric.existingSecret` (or `electric.insecure=true` for development). Always one pod; `persistence.accessModes: [ReadWriteMany]` switches upgrades to a rolling update without downtime. `electric.replicationStreamId` allows only `[a-z0-9_]`. Verify with `helm test <release>`.
- `falkordb`: runs FalkorDB's official `falkordb/falkordb-server` image. `architecture: standalone` (default) or `replication` (`replicaCount` >= 3, Redis Sentinel failover). With replication, clients connect to Sentinel on port 26379 of the Service with primary name `falkordb` and the same password; port 6379 of the Service reaches any pod and is for read-only queries. Password generated in the Secret `<release>-falkordb` (key `password`) unless `auth.existingSecret` is set. Module settings go in `config` (the image's 1-second read `TIMEOUT` is the default). Verify with `helm test <release>`.
- `logto`: uses the official Logto image `svhd/logto`. Requires PostgreSQL 14+ (`database.url` `postgres://...` or `database.existingSecret`) whose user may create roles (`CREATEROLE` or superuser). Redis is optional. A pre-install/pre-upgrade Job seeds the database and deploys Logto's database alterations; Logto does not start without them. Set `endpoint` and `adminConsole.endpoint` to the public URLs. The first visitor of a new Admin Console creates the admin account. Verify with `helm test <release>`.
- `saleor`: uses Saleor's official images. Requires `saleor.publicUrl` (scheme and host only), `saleor.allowedClientHosts`, `saleor.secretKey` + `saleor.rsaPrivateKey` (or `saleor.existingSecret`), PostgreSQL (`database.url`), a Celery broker (`celery.brokerUrl`) and S3 buckets (`storage.s3.mediaBucket`, `storage.s3.privateBucket`); the API and the worker share files through them. Saleor 3.23.41 was tested on PostgreSQL 17 and 18 (Saleor's own CI uses 15); a fresh install of 3.22.73 fails on 18. Verify with `helm test <release>`.
- `xxl-job`: deploys the XXL-JOB admin with the official image `xuxueli/xxl-job-admin` (amd64 only). Requires MySQL (tested 8.4) with an existing utf8mb4 database (`database.host`, `database.username`, `database.password` or `database.existingSecret`). A pre-install/pre-upgrade Job (`mysql:8.4` client) creates missing tables from `files/schema.sql` and, on a database without users, the admin user with `admin.password` or a random password in the chart's Secret (key `admin-password`). It never alters existing tables; schema changes between XXL-JOB releases are applied by hand. Executors set `xxl.job.admin.addresses`, `xxl.job.executor.appname` and `xxl.job.executor.accessToken` (per executor group). Verify with `helm test <release>`.
- `conductor`: requires PostgreSQL (`database.url` as a JDBC URL `jdbc:postgresql://...`, `database.username`, and `database.password` or `database.existingSecret`); nothing else. Any `replicaCount` works, because the chart always uses Conductor's PostgreSQL workflow lock. Conductor has no authentication; never expose the Service or Ingress without auth in front. Other settings go through `extraEnv` as Spring properties (`CONDUCTOR_...`). Verify with `helm test <release>`.

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
- Every chart sets `icon: https://upstreamyard.github.io/helm-charts/logo.png` (the upstreamyard logo, `logo.png` in this repo, published to GitHub Pages by `release.yml`).
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
