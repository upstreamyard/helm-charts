# Postal Helm chart

![Version: 0.1.3](https://img.shields.io/badge/Version-0.1.3-informational?style=flat-square) ![AppVersion: 3.3.7](https://img.shields.io/badge/AppVersion-3.3.7-informational?style=flat-square)

> **Support:** For help with setup, production issues, or hardened and custom images, email [upstreamyard@proton.me](mailto:upstreamyard@proton.me).

Helm chart for [Postal](https://github.com/postalserver/postal), the open-source mail delivery platform for sending and receiving email: an alternative to Sendgrid, Mailgun or Postmark that you run yourself. It runs the web interface and HTTP API, the SMTP server and the workers, using Postal's official image `ghcr.io/postalserver/postal`.

> Community chart by **upstreamyard**, not an official Postal chart. Postal is © Krystal Hosting Ltd and contributors, licensed under MIT.

## Install

Postal needs MariaDB (see [Requirements](#requirements)). Create the keys once and keep them: the signing key is published in your DKIM DNS record, so a new key breaks DKIM for the default return path domain.

```bash
openssl genrsa -out signing.key 2048
kubectl create secret generic postal-keys \
  --from-literal=secret-key="$(openssl rand -hex 64)" \
  --from-file=signing-key=signing.key

helm repo add upstreamyard https://upstreamyard.github.io/helm-charts
helm install postal upstreamyard/postal \
  --set postal.webHostname=postal.example.com \
  --set postal.existingSecret=postal-keys \
  --set database.host=your-mariadb \
  --set database.password='...' \
  --set admin.email=you@example.com --set admin.password='...'
```

Or from the OCI registry:

```bash
helm install postal oci://ghcr.io/upstreamyard/charts/postal --set postal.webHostname=postal.example.com ...
```

The web interface answers on `postal.webHostname` only (route it with `ingress.enabled=true` or your own proxy). Without `admin.*`, create the first admin user with `kubectl exec -it deploy/postal-web -- postal make-user`.

After the install:

1. Publish the DNS records (see [DNS records](#dns-records)).
2. Make the SMTP server reachable from the internet and give Postal a fixed outgoing IP (see [Receiving and sending mail from Kubernetes](#receiving-and-sending-mail-from-kubernetes)).
3. In the web interface, create an organization, a mail server and an SMTP credential, and set `systemEmail.username` and `systemEmail.password` so Postal can send password resets and invitations.

### Verifying the chart

Chart packages are PGP-signed. Import the [public key](https://upstreamyard.github.io/helm-charts/pgp_keys.asc) (fingerprint `9B416F989B7E6C65F7F3BFAE7689688B20EC7813`) and install with `--verify`:

```bash
curl -s https://upstreamyard.github.io/helm-charts/pgp_keys.asc | gpg --dearmor > upstreamyard.gpg
helm install postal upstreamyard/postal --verify --keyring upstreamyard.gpg --set ...
```

The OCI copy on GHCR is signed with cosign instead (see the [repository README](https://github.com/upstreamyard/helm-charts#usage)).

## Requirements

- **MariaDB 10.6 or newer** (required). Postal doesn't support MySQL. Tested with MariaDB 10.6 and 11.8. Postal keeps its configuration in one database (`database.name`) and creates one more database per mail server (`<database.messageDatabasePrefix>-server-<id>`), so the user needs all privileges on both:

  ```sql
  CREATE USER 'postal'@'%' IDENTIFIED BY '...';
  GRANT ALL PRIVILEGES ON `postal`.* TO 'postal'@'%';
  GRANT ALL PRIVILEGES ON `postal-%`.* TO 'postal'@'%';
  ```

  The migration Job creates the main database if it doesn't exist. Set MariaDB's `innodb_log_file_size` to at least 10 times `smtp.maxMessageSize` (e.g. 150 MB for the default 14 MB).
- **amd64 nodes.** The official image is built for `linux/amd64` only. On clusters with arm64 nodes, set `nodeSelector: {kubernetes.io/arch: amd64}`.

This chart does not deploy a database.

## Receiving and sending mail from Kubernetes

A mail server needs fixed public IP addresses that other mail servers trust. This is the part of running Postal on Kubernetes that needs planning; none of it is specific to this chart, but a single VM gets it for free.

**Incoming mail.** Other mail servers connect to port 25 of the IP your MX records point to.

- Expose the SMTP server with `smtp.service.type=LoadBalancer` and a fixed IP (`smtp.service.loadBalancerIP` or your cloud's annotation in `smtp.service.annotations`). Give it its own name with `postal.smtpHostname` (e.g. `smtp.postal.example.com`), unless the web interface uses the same IP; the MX records default to that name.
- Postal must see the sender's real IP for spam checks and logs. Either set `smtp.service.externalTrafficPolicy=Local`, or let the load balancer send the PROXY protocol header and set `smtp.proxyProtocol=true`. Postal only reads **PROXY protocol v1** (the text format); load balancers that only send v2 (e.g. AWS NLB) don't work with it.
- Your apps can send through the same Service, on port 25 or an extra port such as 587 (`smtp.service.ports`).

**Outgoing mail.** Workers connect to port 25 of the recipients' mail servers.

- Pods send from the IP of their node or NAT gateway. Route the workers' traffic through **one fixed outgoing IP** (a NAT gateway, an egress gateway, or dedicated nodes with `nodeSelector`), set its reverse DNS (PTR) to `dns.heloHostname` (defaults to `postal.smtpHostname`), and list it in your SPF record. Without this, Gmail and others put your mail in spam or reject it.
- Many clouds (AWS, Google Cloud, Azure and others) block outgoing port 25 by default. Ask your provider to lift it, or send through a relay with `postal.smtpRelays`.
- Postal's IP pools (sending from several IPs) need host networking and aren't supported by this chart.

The load balancer and outgoing-IP setups depend on your cloud and were not tested by us. Postal reading the client IP from a PROXY v1 header was tested in kind.

## DNS records

With `postal.webHostname=postal.example.com`, `postal.smtpHostname=smtp.postal.example.com` and the default `dns.*` values, publish:

| Name | Type | Value |
|---|---|---|
| `postal.example.com` | A / AAAA | your Ingress IP (web interface and API) |
| `smtp.postal.example.com` | A / AAAA | the SMTP load balancer IP (also the MX host) |
| `spf.postal.example.com` | TXT | `v=spf1 ip4:<outgoing IP> ~all` |
| `rp.postal.example.com` | MX | `10 smtp.postal.example.com` |
| `rp.postal.example.com` | TXT | `v=spf1 a mx include:spf.postal.example.com ~all` |
| `postal._domainkey.rp.postal.example.com` | TXT | output of `kubectl exec deploy/postal-web -- postal default-dkim-record` |
| `routes.postal.example.com` | MX | `10 smtp.postal.example.com` |
| `track.postal.example.com` | A / AAAA | your Ingress IP (only for click and open tracking) |

If the web interface and the SMTP server share one IP, leave `postal.smtpHostname` empty and use `postal.example.com` wherever `smtp.postal.example.com` appears.

Postal shows each sending domain's own records in the web interface and checks them.

## What the chart does

- **Three Deployments** from the same image: `web` (web interface, HTTP API, tracking; port 5000), `smtp` (SMTP server; port 2525 in the container, 25 on the Service) and `worker` (delivery, incoming processing, webhooks, housekeeping). All three scale freely: Postal coordinates through the database, and the workers elect one of themselves for housekeeping. Tested with 2 replicas each, including a login on one web pod used on the other.
- **Configuration by environment variables**, so no `postal.yml` is needed. The DNS names default to subdomains of `postal.webHostname`.
- **Migrations:** a Job runs `postal initialize` before every install and upgrade (Helm hook). It creates the database if needed, loads the schema on a fresh database or migrates it, migrates every mail server's database, and creates the admin user from `admin.*` if it doesn't exist. New pods wait for pending migrations instead of failing.
- **Graceful shutdown:** the image's `postal <command>` wrapper is a bash script that runs Ruby as a child, so SIGTERM never reaches Postal and every pod is killed after its grace period; a killed worker leaves the message it was delivering locked for a day. The chart starts the processes directly, so Postal receives SIGTERM: workers finish their message, the SMTP server stops accepting connections and finishes open sessions, and a 10 s `preStop` sleep keeps a stopping web pod serving until it has left the Service. Tested: SMTP and worker pods stop within 1 s and log Postal's shutdown, web pods within 12 s (10 s of it the `preStop` sleep), instead of being killed after the grace period.
- **Probes:** the web server is probed on `/.well-known/jwks.json` with the `Host` header set to `postal.webHostname` (it rejects other hosts); the SMTP server and workers on their health servers (`/health` on ports 9091 and 9090).
- **Metrics:** the SMTP servers and workers serve Prometheus metrics on `/metrics` (port `health`); `metrics.podMonitor.enabled=true` creates a PodMonitor.
- **Security:** runs as non-root (the image's `postal` user, UID 999), read-only root filesystem, no ServiceAccount token, and meets the Kubernetes `restricted` Pod Security Standard (tested). The image's Ruby carries the `cap_net_bind_service` file capability, and Linux refuses to start a program whose file capabilities are missing from the bounding set, so the chart drops all capabilities except `NET_BIND_SERVICE`. With `allowPrivilegeEscalation: false` the processes don't get it; they run without any capabilities (tested). Secrets come from a Secret created by the chart or from your own (`existingSecret` for every credential).
- **STARTTLS** with a `kubernetes.io/tls` Secret, e.g. from cert-manager (`smtp.tls.*`).
- **`helm test`** loads the login page and the signing key's public JWKS through the web Service, and checks that the SMTP Service greets and answers `EHLO`.

Tested end to end in kind: an app sent a message through the SMTP Service with an SMTP credential, a worker DKIM-signed it and delivered it through a relay; incoming mail to a route was accepted and processed; Postal's own emails went through `systemEmail`; and an upgrade from Postal 3.3.6 to 3.3.7 ran the migration Job and rolled all pods.

## Configuration

Every Postal setting is an environment variable; set the ones the chart doesn't cover with `extraEnv` (plain values) or `extraEnvFrom` (Secrets), e.g. spam and virus checks (`RSPAMD_*`, `SPAMD_*`, `CLAMAV_*`), single sign-on (`OIDC_*`), Sentry (`LOGGING_SENTRY_DSN`) or delivery limits. See Postal's [list of environment variables](https://github.com/postalserver/postal/blob/main/doc/config/environment-variables.md). A `postal.yml` mounted at `/config/postal.yml` (`extraVolumes`, `extraVolumeMounts`) is read too, but the chart's environment variables take precedence.

- **Relay hostnames must be fully qualified.** Postal resolves them with its own DNS client, which ignores the cluster's search domains: `smtp://relay.mail.svc.cluster.local:25` works, `smtp://relay.mail.svc:25` fails with "No SMTP servers were available".
- **Click and open tracking:** Postal serves tracking requests from the web server when the proxy adds the header `X-Postal-Track-Host: 1` for tracking hosts. The chart's Ingress doesn't add it; route your tracking hosts through a proxy that does. Not tested by us.
- **Client IPs in the web interface:** set `postal.trustedProxies` to your Ingress controller's pod network so Postal takes the client IP from `X-Forwarded-For`.
- **Your own migrations:** with `migrations.enabled=false`, run `kubectl exec deploy/postal-web -- postal upgrade` after an upgrade; new pods wait until the migrations are applied (and restart if that takes longer than their probes allow). Keep the Job on for the first install: on an empty database the pods crash until the schema exists.

## Production example

```yaml
# values-prod.yaml
postal:
  webHostname: postal.example.com
  smtpHostname: smtp.postal.example.com
  existingSecret: postal-keys          # keys: secret-key, signing-key
  trustedProxies: ["10.0.0.0/8"]
database:
  host: mariadb.databases.svc
  existingSecret: postal-db            # key: password
systemEmail:
  username: postal/system              # an SMTP credential created in the web interface
  existingSecret: postal-smtp          # key: smtp-password
web:
  replicaCount: 2
smtp:
  replicaCount: 2
  tls:
    enabled: true
    secretName: postal-smtp-tls        # e.g. a cert-manager Certificate for postal.example.com
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
    ports:
      - name: smtp
        port: 25
      - name: submission
        port: 587
worker:
  replicaCount: 2
nodeSelector:
  kubernetes.io/arch: amd64
ingress:
  enabled: true
  className: nginx
  tls:
    - hosts: [postal.example.com]
      secretName: postal-web-tls
metrics:
  podMonitor:
    enabled: true
```

## Known issues

- **The official image is amd64 only.** Pods scheduled on arm64 nodes fail with `exec format error`.
- **Postal's own `postal <command>` wrapper doesn't pass on SIGTERM** (see [What the chart does](#what-the-chart-does)). The chart works around it; if you override the container args, keep Ruby as the main process.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| admin.email | string | `""` | Email of the first admin user. Leave empty to create it yourself with `postal make-user` (see the README). |
| admin.existingSecret | string | `""` | Name of an existing Secret that holds the admin password. |
| admin.existingSecretKey | string | `"admin-password"` | Key in `existingSecret` that holds the admin password. |
| admin.firstName | string | `"Postal"` | First name of the admin user. |
| admin.lastName | string | `"Admin"` | Last name of the admin user. |
| admin.password | string | `""` | Password of the admin user. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| affinity | object | `{}` | Affinity. |
| database.existingSecret | string | `""` | Name of an existing Secret that holds the password (recommended for production). |
| database.existingSecretKey | string | `"password"` | Key in `existingSecret` that holds the password. |
| database.host | string | `""` | Hostname of the MariaDB server (`MAIN_DB_HOST`, `MESSAGE_DB_HOST`). Required. |
| database.messageDatabasePrefix | string | `"postal"` | Prefix of the per-mail-server databases (`MESSAGE_DB_DATABASE_NAME_PREFIX`). |
| database.name | string | `"postal"` | Name of the main database (`MAIN_DB_DATABASE`). Created by the migration Job if it doesn't exist. |
| database.password | string | `""` | Password of the database user. Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| database.port | int | `3306` | Port of the MariaDB server. |
| database.username | string | `"postal"` | Database user. |
| dns.dkimIdentifier | string | `"postal"` | DKIM selector (`DNS_DKIM_IDENTIFIER`). |
| dns.heloHostname | string | `""` | Hostname Postal uses in `HELO`/`EHLO` when it delivers mail (`DNS_HELO_HOSTNAME`). Should match the reverse DNS (PTR) of your outgoing IP. Defaults to `smtpHostname`. |
| dns.mxRecords | list | `[]` | MX hosts for incoming mail (`DNS_MX_RECORDS`). Defaults to `[smtpHostname]`. |
| dns.returnPathDomain | string | `""` | Default return path domain (`DNS_RETURN_PATH_DOMAIN`). Bounces go here. Defaults to `rp.<webHostname>`. |
| dns.routeDomain | string | `""` | Domain for route forwarding addresses (`DNS_ROUTE_DOMAIN`). Defaults to `routes.<webHostname>`. |
| dns.spfInclude | string | `""` | Name of the TXT record with the SPF policy that sending domains include (`DNS_SPF_INCLUDE`). Defaults to `spf.<webHostname>`. |
| dns.trackDomain | string | `""` | Domain that sending domains' tracking CNAMEs point to (`DNS_TRACK_DOMAIN`). Defaults to `track.<webHostname>`. |
| extraEnv | list | `[]` | Extra environment variables for all Postal containers, e.g. any Postal setting such as `LOGGING_SENTRY_DSN`, `RSPAMD_ENABLED` or `OIDC_ENABLED`. |
| extraEnvFrom | list | `[]` | Extra environment variables from Secrets or ConfigMaps. |
| extraVolumeMounts | list | `[]` | Extra volume mounts for all Postal containers. A `postal.yml` mounted at `/config/postal.yml` is read, but the chart's environment variables take precedence. |
| extraVolumes | list | `[]` | Extra volumes for all Postal pods, e.g. a ConfigMap with a `postal.yml`. |
| fullnameOverride | string | `""` | Override the full resource name. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/postalserver/postal"` | Image repository, used for the web server, SMTP server, workers and the migration Job. |
| image.tag | string | `""` | Image tag. Defaults to the chart's appVersion. |
| imagePullSecrets | list | `[]` | Secrets for pulling from a private registry. |
| ingress.annotations | object | `{}` | Ingress annotations. |
| ingress.className | string | `""` | Ingress class name. |
| ingress.enabled | bool | `false` | Create an Ingress for the web interface and API. |
| ingress.hosts | list | `[]` | Ingress hosts. Defaults to `postal.webHostname` with path `/`. |
| ingress.tls | list | `[]` | Ingress TLS configuration. |
| metrics.podMonitor.enabled | bool | `false` | Create a Prometheus Operator PodMonitor that scrapes `/metrics` of the SMTP servers and workers (needs the `monitoring.coreos.com` CRDs). |
| metrics.podMonitor.interval | string | `"30s"` | Scrape interval. |
| metrics.podMonitor.labels | object | `{}` | Extra labels for the PodMonitor, e.g. the label your Prometheus selects on. |
| migrations.activeDeadlineSeconds | int | `1800` | Maximum runtime of the migration Job in seconds. |
| migrations.backoffLimit | int | `2` | Retries of the migration Job before the install/upgrade fails. |
| migrations.enabled | bool | `true` | Run `postal initialize` (creates the database if needed, loads the schema or migrates it, including all mail server databases) in a Job (Helm hook) before every install and upgrade. If false, run `postal upgrade` yourself; until then new pods wait for pending migrations. Keep it on for the first install: on an empty database the pods crash until the schema exists. |
| migrations.resources | object | `{"limits":{"memory":"768Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}` | Resources for the migration Job. |
| nameOverride | string | `""` | Override the chart name in resource names. |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Extra pod annotations. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":999,"runAsGroup":999,"runAsNonRoot":true,"runAsUser":999,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. The image's `postal` user is UID 999. |
| postal.existingSecret | string | `""` | Name of an existing Secret that holds the secret key and the signing key (recommended for production). |
| postal.secretKey | string | `""` | Rails secret key that signs sessions (`RAILS_SECRET_KEY`), e.g. from `openssl rand -hex 64`. All pods must share it. Required unless `existingSecret` is set. Stored in a Secret created by this chart. |
| postal.secretKeyKey | string | `"secret-key"` | Key in `existingSecret` that holds the Rails secret key. |
| postal.signingKey | string | `""` | RSA private key in PEM format, e.g. from `openssl genrsa 2048` (mounted as `signing.key`). Signs messages with the default DKIM key of the return path domain and webhooks. Changing it invalidates the published DKIM record. Required unless `existingSecret` is set. Stored in a Secret created by this chart. |
| postal.signingKeyKey | string | `"signing-key"` | Key in `existingSecret` that holds the signing key. |
| postal.smtpHostname | string | `""` | Hostname of the SMTP server, shown to users as the server to send through (`POSTAL_SMTP_HOSTNAME`), e.g. `smtp.postal.example.com`. Set it when the SMTP load balancer has a different IP than the web interface. Defaults to `webHostname`. |
| postal.smtpRelays | list | `[]` | Send all outgoing mail through these relays instead of delivering it directly, e.g. `["smtp://relay.example.com:587?ssl_mode=Auto"]` (`POSTAL_SMTP_RELAYS`); `ssl_mode` is `None`, `Auto`, `STARTTLS` or `TLS`. Use it when your cloud blocks outgoing port 25. Hostnames must be fully qualified (`relay.mail.svc.cluster.local`, not `relay.mail.svc`): Postal's resolver ignores the cluster's search domains. |
| postal.trustedProxies | list | `[]` | IP addresses or CIDR ranges of proxies in front of the web server, e.g. your Ingress controller's pod network (`POSTAL_TRUSTED_PROXIES`). Postal then takes the client IP from `X-Forwarded-For`. |
| postal.webHostname | string | `""` | Hostname of the web interface and API, e.g. `postal.example.com` (`POSTAL_WEB_HOSTNAME`). The web server only answers requests for this host. Required. |
| postal.webProtocol | string | `"https"` | Protocol of the web interface as users reach it (`POSTAL_WEB_PROTOCOL`). Used in links Postal generates. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"add":["NET_BIND_SERVICE"],"drop":["ALL"]},"readOnlyRootFilesystem":true}` | Container security context. The image's Ruby carries the `cap_net_bind_service` file capability, and Linux refuses to start a program whose file capabilities are missing from the bounding set, so `NET_BIND_SERVICE` stays in it. With `allowPrivilegeEscalation: false` the processes don't get the capability; they run without any. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.automount | bool | `false` | Mount the ServiceAccount token. Postal does not use the Kubernetes API. |
| serviceAccount.create | bool | `true` | Create a ServiceAccount. |
| serviceAccount.name | string | `""` | ServiceAccount name. Generated from the full name if empty. |
| smtp.bindAddress | string | `"0.0.0.0"` | Bind address (`SMTP_SERVER_DEFAULT_BIND_ADDRESS`). Use `::` for IPv4 and IPv6 on dual-stack clusters. |
| smtp.containerPort | int | `2525` | Port the SMTP server listens on inside the container. Above 1024, so it needs no privileges; the Service maps port 25 to it. |
| smtp.livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/health","port":"health"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on the health server (`/health`, port 9091). |
| smtp.maxMessageSize | int | `14` | Maximum message size in MB (`SMTP_SERVER_MAX_MESSAGE_SIZE`). MariaDB's `innodb_log_file_size` must be at least 10 times this. |
| smtp.proxyProtocol | bool | `false` | Expect the PROXY protocol header from the load balancer (`SMTP_SERVER_PROXY_PROTOCOL`), so Postal sees the sender's real IP. Every connection must then come through a proxy that sends it. |
| smtp.readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/health","port":"health"},"periodSeconds":5,"timeoutSeconds":3}` | Readiness probe on the health server. (A TCP probe on the SMTP port would log a broken-pipe error for every check.) |
| smtp.replicaCount | int | `1` | SMTP server pods. They receive mail from other mail servers and from your apps. Any number works. |
| smtp.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"256Mi"}}` | Resources for the SMTP server container. |
| smtp.service.annotations | object | `{}` | Service annotations, e.g. for your cloud's load balancer. |
| smtp.service.externalTrafficPolicy | string | `""` | `externalTrafficPolicy` for `LoadBalancer`/`NodePort`. `Local` keeps the sender's IP (needed for spam checks and logs) without the PROXY protocol. |
| smtp.service.loadBalancerIP | string | `""` | Fixed IP for a `LoadBalancer` Service (if your provider supports `loadBalancerIP`; many use an annotation instead). |
| smtp.service.ports | list | `[{"name":"smtp","port":25}]` | Service ports, all forwarded to the SMTP server. Port 25 is for other mail servers; add 587 for your apps if you like (Postal serves both on the same listener). Each entry takes `name`, `port` and optionally `nodePort`. |
| smtp.service.type | string | `"ClusterIP"` | Service type. Use `LoadBalancer` to receive mail from the internet; see the README for the IP setup. |
| smtp.startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/health","port":"health"},"periodSeconds":3,"timeoutSeconds":3}` | Startup probe on the health server. |
| smtp.terminationGracePeriodSeconds | int | `60` | Seconds Kubernetes waits after SIGTERM. The SMTP server stops accepting connections and finishes open sessions. |
| smtp.tls.enabled | bool | `false` | Offer STARTTLS (`SMTP_SERVER_TLS_ENABLED`). Needs `secretName`. |
| smtp.tls.secretName | string | `""` | Name of a `kubernetes.io/tls` Secret (`tls.crt`, `tls.key`) for `postal.smtpHostname`, e.g. from cert-manager. |
| systemEmail.existingSecret | string | `""` | Name of an existing Secret that holds the SMTP password. |
| systemEmail.existingSecretKey | string | `"smtp-password"` | Key in `existingSecret` that holds the SMTP password. |
| systemEmail.fromAddress | string | `""` | Sender address (`SMTP_FROM_ADDRESS`). Defaults to `postal@<webHostname>`. |
| systemEmail.fromName | string | `"Postal"` | Sender name (`SMTP_FROM_NAME`). |
| systemEmail.host | string | `""` | SMTP host (`SMTP_HOST`). Defaults to this release's SMTP Service. |
| systemEmail.password | string | `""` | SMTP password (`SMTP_PASSWORD`). Stored in a Secret created by this chart. Ignored when `existingSecret` is set. |
| systemEmail.port | int | `25` | SMTP port (`SMTP_PORT`). |
| systemEmail.username | string | `""` | SMTP username (`SMTP_USERNAME`). |
| tolerations | list | `[]` | Tolerations. |
| web.lifecycle | object | `{"preStop":{"exec":{"command":["sleep","10"]}}}` | Lifecycle hooks. The `preStop` sleep keeps a stopping pod serving until it is removed from the Service's endpoints. |
| web.livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/.well-known/jwks.json","port":"http"},"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe. The chart adds the `Host` header. |
| web.maxThreads | int | `5` | Request threads per web server pod (`WEB_SERVER_MAX_THREADS`). |
| web.readinessProbe | object | `{"failureThreshold":3,"httpGet":{"path":"/.well-known/jwks.json","port":"http"},"periodSeconds":5,"timeoutSeconds":3}` | Readiness probe. The chart adds the `Host` header. |
| web.replicaCount | int | `1` | Web server pods (web interface, HTTP API, click and open tracking). Any number works. |
| web.resources | object | `{"limits":{"memory":"768Mi"},"requests":{"cpu":"100m","memory":"384Mi"}}` | Resources for the web server container. |
| web.service.port | int | `80` | Service port. The web server listens on 5000 inside the container. |
| web.service.type | string | `"ClusterIP"` | Service type. |
| web.startupProbe | object | `{"failureThreshold":60,"httpGet":{"path":"/.well-known/jwks.json","port":"http"},"periodSeconds":3,"timeoutSeconds":3}` | Startup probe. The chart adds the `Host` header (`postal.webHostname`), because the web server rejects other hosts. |
| web.terminationGracePeriodSeconds | int | `40` | Seconds Kubernetes waits after SIGTERM, including the `preStop` sleep. |
| worker.livenessProbe | object | `{"failureThreshold":6,"httpGet":{"path":"/health","port":"health"},"initialDelaySeconds":30,"periodSeconds":10,"timeoutSeconds":5}` | Liveness probe on the health server (`/health`, port 9090). |
| worker.replicaCount | int | `1` | Worker pods. They deliver outgoing mail, process incoming mail, send webhooks and run housekeeping (one worker is elected for it). Any number works. |
| worker.resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"50m","memory":"256Mi"}}` | Resources for the worker container. |
| worker.terminationGracePeriodSeconds | int | `120` | Seconds Kubernetes waits after SIGTERM. Workers finish the message they are delivering; a killed worker leaves it locked for a day (`POSTAL_QUEUED_MESSAGE_LOCK_STALE_DAYS`). |
| worker.threads | int | `2` | Threads per worker pod (`WORKER_THREADS`). |
