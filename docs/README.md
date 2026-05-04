# CS-Traefik Documentation

Comprehensive reference for the CS-Traefik stack. The repository
[`README.md`](../README.md) covers the high-level overview and one-line
install -- this directory holds the in-depth material.

## Getting started

| Doc | What's in it |
| --- | --- |
| [`installation.md`](installation.md) | Detailed install (manual + automated), prerequisites, post-install verification. |
| [`configuration.md`](configuration.md) | Complete `.env` reference -- every variable with default, semantics, and side effects. |
| [`profiles.md`](profiles.md) | The three Compose profiles (`core` / `monitoring` / `auto-update`) and how `traefik.sh` wires them. |

## Networking & TLS

| Doc | What's in it |
| --- | --- |
| [`networking.md`](networking.md) | EDGEPROXY public + EDGEPROXY-INTERNAL networks, IPv4/IPv6 dual-stack, port assignments, when to override. |
| [`tls-and-certificates.md`](tls-and-certificates.md) | Let's Encrypt resolvers (HTTP-01 / TLS-ALPN-01 / DNS-01), 24+ DNS providers, manual / corporate-CA certificates, mTLS, TLS-options profiles. |
| [`admin-access.md`](admin-access.md) | The `api` entrypoint, three access modes (localhost / LAN / public FQDN), BasicAuth + IP whitelist. |

## Routing & policy

| Doc | What's in it |
| --- | --- |
| [`middlewares.md`](middlewares.md) | Full catalog of opt-in middlewares (security headers, CORS, rate-limits, retry, circuit-breaker, forward-auth, ...). |
| [`custom-config.md`](custom-config.md) | The file-provider for routes that aren't in Docker labels (VMs, on-prem, external SaaS). |

## Observability

| Doc | What's in it |
| --- | --- |
| [`monitoring.md`](monitoring.md) | Prometheus + Grafana + Loki + Promtail + Alertmanager + node-exporter + cAdvisor. Pre-provisioned dashboards. |

## Examples

| Example | Use case |
| --- | --- |
| [`examples/basic-webapp.md`](examples/basic-webapp.md) | Standard public-facing web application (HTTPS, HSTS, app-level redirect). |
| [`examples/minio-s3.md`](examples/minio-s3.md) | MinIO / S3 behind Traefik -- multipart uploads, streaming, no buffering. |
| [`examples/api-with-rate-limit.md`](examples/api-with-rate-limit.md) | API backend with body-limit, rate-limit, and CORS. |
| [`examples/wildcard-cert-cloudflare.md`](examples/wildcard-cert-cloudflare.md) | Wildcard `*.bauer-group.com` via DNS-01 + Cloudflare. |
| [`examples/forward-auth-authelia.md`](examples/forward-auth-authelia.md) | SSO across multiple apps via Authelia forward-auth. |
| [`examples/on-prem-vm-via-file-provider.md`](examples/on-prem-vm-via-file-provider.md) | Routing to a VM / appliance that doesn't run in Docker. |

## Operations

| Doc | What's in it |
| --- | --- |
| [`operations/migration-from-v2.md`](operations/migration-from-v2.md) | Migrating from the legacy v2.x EDGEPROXY stack. Drop-in compatibility points + caveats. |
| [`operations/troubleshooting.md`](operations/troubleshooting.md) | Symptoms → causes → fixes. ACME failures, 502/503 patterns, log explosion, dashboard 404s. |
| [`operations/backup-restore.md`](operations/backup-restore.md) | What `traefik.sh backup` archives, how to restore, what's NOT in the backup. |
| [`operations/upgrades.md`](operations/upgrades.md) | Updating images vs. updating the stack scripts. Traefik major-version upgrade pattern. |

## Reading order for new operators

1. [`../README.md`](../README.md) -- the 5-minute pitch.
2. [`installation.md`](installation.md) -- get a working stack.
3. [`configuration.md`](configuration.md) -- understand every knob.
4. [`examples/basic-webapp.md`](examples/basic-webapp.md) -- attach your first app.
5. [`middlewares.md`](middlewares.md) -- pick the security policy your app needs.
6. [`monitoring.md`](monitoring.md) -- turn on observability.
7. [`operations/troubleshooting.md`](operations/troubleshooting.md) -- bookmark for later.
