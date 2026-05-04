# Configuration Reference

Every variable in [`.env.example`](../.env.example), grouped by concern,
with default value, semantics, and the side-effects of changing it.

The wizard (`./install.sh` or `./traefik.sh setup`) generates a sane
starting `.env`. This page documents what each value does so you can
adjust safely.

## Stack identity

| Variable | Default | Notes |
| --- | --- | --- |
| `STACK_NAME` | `edgeproxy` | Compose project name. Prefixes container/volume names. Change only if you run multiple Traefik stacks on the same host. |
| `NETWORK_NAME` | `EDGEPROXY` | Public Docker network name. **Drop-in compat with the legacy v2 stack** — change at your own risk; existing app stacks reference this. |
| `TIME_ZONE` | `Etc/UTC` | IANA timezone, propagated to every container's `TZ` env var. Affects log timestamps and cron schedules. |
| `DATA_DIRECTORY` | `/opt/edgeproxy` | Host path for runtime state (ACME, Grafana DB, Prometheus TSDB, Loki chunks, logs, backups). Use a separate disk for log-heavy workloads. |

## Compose profiles (feature toggles)

| Variable | Default | Notes |
| --- | --- | --- |
| `COMPOSE_PROFILES` | *(empty)* | Activate optional features. Comma-separated. Compose-native. |

Values:

- *(empty)* — core only (just Traefik). The default.
- `monitoring` — adds Prometheus, Grafana, Loki, Promtail, Alertmanager,
  node-exporter, cAdvisor.
- `auto-update` — adds Watchtower (rolling, weekly cron).
- `monitoring,auto-update` — both.

## Traefik core

| Variable | Default | Notes |
| --- | --- | --- |
| `TRAEFIK_IMAGE_TAG` | `v3.6` | Pin to a minor in production. Watchtower (if active) honours this -- a `latest` tag floats; a pinned tag stays. |
| `HTTP_PORT` | `80` | External HTTP port. Change if Traefik must coexist with another listener on 80. |
| `HTTPS_PORT` | `443` | External HTTPS port. Used for both TCP (HTTP/1.1, HTTP/2) and UDP (HTTP/3 / QUIC). |
| `LOG_LEVEL` | `INFO` | One of `ERROR / WARN / INFO / DEBUG / TRACE`. DEBUG logs every routing decision -- use only for active debugging. |
| `ACCESS_LOG_FORMAT` | `json` | `common` (Apache combined) or `json`. JSON works with Loki / Promtail label parsing. |
| `WEB_READ_TIMEOUT` | `0s` | Max time to read a request body. `0s` = unlimited (required for S3/MinIO multipart, large uploads). Bump to e.g. `600s` for slowloris hardening. |
| `WEB_WRITE_TIMEOUT` | `0s` | Max time to write a response. `0s` = unlimited (required for SSE / streaming). |
| `WEB_IDLE_TIMEOUT` | `300s` | Idle keepalive timeout. 5 min covers most WebSocket apps without aggressive heartbeats. Bump to `600s` for IoT / MQTT-over-WS; lower to `60s` for memory-tight setups. |

## Admin access (`api` entrypoint)

The Traefik dashboard, Grafana, Prometheus, and Alertmanager are
reached via path-prefix routing on a dedicated `api` entrypoint.
**Never** on the public 443 port unless you set `API_HOST`.

| Variable | Default | Notes |
| --- | --- | --- |
| `API_PORT` | `9090` | Internal port for the admin entrypoint. Any free port. |
| `API_BIND` | `127.0.0.1` | IPv4 bind interface. `127.0.0.1` = loopback only (default, most secure). `0.0.0.0` = LAN-accessible. |
| `API_BIND_V6` | `::1` | IPv6 bind. Set to `::` for LAN-accessible IPv6. Always set in lock-step with `API_BIND`. |
| `API_HOST` | *(empty)* | Optional FQDN for HTTPS-on-443 admin access. **Pick a hostname that hosts no application** (e.g. `admin.bauer-group.com`). |
| `API_BASE_URL` | `http://localhost:9090` | Used by Grafana / Prometheus / Alertmanager to build self-links. Set to `https://${API_HOST}` if `API_HOST` is set. |
| `API_WHITELIST` | `127.0.0.1/32, ::1/128, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12` | IP whitelist (CIDRs). Always enforced for admin surfaces. |
| `API_USERS` | `admin/admin` (bcrypt) | htpasswd format with bcrypt. Generate via `echo $(htpasswd -nB admin) \| sed -e 's/\$/\$\$/g'`. **Change the default before exposing**. |

See [`admin-access.md`](admin-access.md) for the three usage modes
(localhost / LAN / public FQDN).

## Let's Encrypt

| Variable | Default | Notes |
| --- | --- | --- |
| `LETSENCRYPT_EMAIL` | `info@bauer-group.com` | ACME registration + expiry notifications. **Required**. Override per deployment in `.env`. |
| `LETSENCRYPT_CA` | `https://acme-v02.api.letsencrypt.org/directory` | Production endpoint. Switch to `https://acme-staging-v02.api.letsencrypt.org/directory` while testing to avoid the production rate limit (5 duplicate certs/week). |

Four resolvers are pre-wired in [`config/traefik/traefik.yml`](../config/traefik/traefik.yml):

| Resolver | Challenge | When |
| --- | --- | --- |
| `letsencrypt` | HTTP-01 (port 80) | DEFAULT. RFC 8555 MUST-implement. |
| `letsencrypt-tls` | TLS-ALPN-01 (port 443) | Fallback when port 80 is fronted. |
| `letsencrypt-dns` | DNS-01 | Wildcards / firewalled hosts. Provider via `LETSENCRYPT_DNS_PROVIDER`. |
| `letsencrypt-staging` | HTTP-01 (staging) | Initial roll-out testing. |

Apps select per-router via `traefik.http.routers.X.tls.certresolver=`.

## DNS-01 challenge (wildcard certificates)

`LETSENCRYPT_DNS_PROVIDER` is the provider key. Empty = DNS-01
disabled. See [`tls-and-certificates.md`](tls-and-certificates.md) for
the full provider list and required env vars per provider.

Most-used providers in BG context:

| Provider | `LETSENCRYPT_DNS_PROVIDER=` | Required env vars |
| --- | --- | --- |
| Cloudflare | `cloudflare` | `CF_DNS_API_TOKEN` |
| Hetzner | `hetzner` | `HETZNER_API_KEY` |
| AWS Route 53 | `route53` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` |
| Azure DNS | `azuredns` | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP` |
| IONOS | `ionos` | `IONOS_API_KEY` |
| Netcup | `netcup` | `NETCUP_CUSTOMER_NUMBER`, `NETCUP_API_KEY`, `NETCUP_API_PASSWORD` |
| INWX | `inwx` | `INWX_USERNAME`, `INWX_PASSWORD`, optionally `INWX_SHARED_SECRET` |

24 providers are pre-wired (Cloudflare, Route 53, GCP, Azure, Hetzner,
IONOS, Netcup, INWX, Hosting.de, DigitalOcean, Linode, Vultr, OVH,
Gandi, DNSimple, Namecheap, GoDaddy, DNSPod, Tencent, Scaleway,
DuckDNS, Designate, ACME-DNS, RFC 2136, exec). Providers not in this
list still work — just add the env vars they need to `.env` (Compose
passes them through automatically).

## Monitoring profile (only active when `monitoring` is in `COMPOSE_PROFILES`)

| Variable | Default | Notes |
| --- | --- | --- |
| `PROMETHEUS_IMAGE_TAG` | `latest` | Pin a digest in regulated environments. |
| `GRAFANA_IMAGE_TAG` | `latest` | |
| `LOKI_IMAGE_TAG` | `latest` | |
| `PROMTAIL_IMAGE_TAG` | `latest` | |
| `ALERTMANAGER_IMAGE_TAG` | `latest` | |
| `CADVISOR_IMAGE_TAG` | `latest` | |
| `NODE_EXPORTER_IMAGE_TAG` | `latest` | |
| `GRAFANA_ADMIN_USER` | `admin` | Grafana's own admin user (separate from `API_USERS`). |
| `GRAFANA_ADMIN_PASSWORD` | `changeme` | **Change before exposing**. |
| `GRAFANA_PLUGINS` | *(empty)* | Comma-separated list of Grafana plugins installed on first start. |
| `PROMETHEUS_RETENTION_TIME` | `30d` | Whichever (time or size) hits first wins. |
| `PROMETHEUS_RETENTION_SIZE` | `8GB` | |
| `PROMETHEUS_SCRAPE_INTERVAL` | `15s` | 5s for fine-grained latency graphs; 30s for low-overhead. |
| `LOKI_RETENTION_PERIOD` | `168h` | 7 days. Increase for compliance / long-tail debugging. |

## Auto-update profile (only active when `auto-update` is in `COMPOSE_PROFILES`)

| Variable | Default | Notes |
| --- | --- | --- |
| `WATCHTOWER_IMAGE` | `nickfedor/watchtower:latest` | Community fork with rolling-restart. Switch to `containrrr/watchtower:latest` for the upstream original. |
| `WATCHTOWER_SCHEDULE` | `0 0 3 * * 6` | Six-field cron. Sat 03:00 by default. |
| `WATCHTOWER_TIMEOUT` | `60s` | Match the longest `stop_grace_period` in the stack. |
| `WATCHTOWER_NOTIFICATIONS` | *(empty)* | Slack / email / Telegram. See `.env.example` for templates. |

## Resource limits

Traefik is **uncapped** (CFS throttling on the request path = visible
502s). All other helpers have realistic caps that protect the host
against runaway scenarios. The non-blocking json-file driver
(`mode: non-blocking`) decouples helper failures from Traefik request
handling, so cap-violations cannot cascade.

| Variable | Default | Service |
| --- | --- | --- |
| `PROMETHEUS_CPU_LIMIT` | `4` | Prometheus |
| `PROMETHEUS_MEMORY_LIMIT` | `4g` | |
| `GRAFANA_CPU_LIMIT` | `2` | Grafana |
| `GRAFANA_MEMORY_LIMIT` | `1g` | |
| `LOKI_CPU_LIMIT` | `2` | Loki |
| `LOKI_MEMORY_LIMIT` | `2g` | |
| `PROMTAIL_CPU_LIMIT` | `1` | Promtail |
| `PROMTAIL_MEMORY_LIMIT` | `512m` | |
| `ALERTMANAGER_CPU_LIMIT` | `1` | Alertmanager |
| `ALERTMANAGER_MEMORY_LIMIT` | `256m` | |
| `NODE_EXPORTER_CPU_LIMIT` | `1` | node-exporter |
| `NODE_EXPORTER_MEMORY_LIMIT` | `128m` | |
| `CADVISOR_CPU_LIMIT` | `1` | cAdvisor |
| `CADVISOR_MEMORY_LIMIT` | `512m` | |
| `WATCHTOWER_CPU_LIMIT` | `1` | Watchtower |
| `WATCHTOWER_MEMORY_LIMIT` | `256m` | |

To override Traefik's (intentionally absent) caps, add a
`docker-compose.override.yml` at the repo root — Compose merges it
automatically.

## Logging

| Variable | Default | Notes |
| --- | --- | --- |
| `LOG_MAX_BUFFER_SIZE` | `4m` | Per-container ring buffer for the json-file driver in `mode: non-blocking`. ~10-50k log lines depending on length. Critical guarantee: when full, lines are dropped instead of blocking the application. |
| `LOG_MAX_SIZE` | `50m` | Per-rotated-file size cap. |
| `LOG_MAX_FILE` | `5` | Number of rotated files to keep. Default = 50m × 5 = 250 MB max per container. |

## What NOT to set

The `.env.example` documents these explicitly so you know they exist
but don't need touching:

- `TRAEFIK_TRUSTED_IPS` — currently unused (kept for future
  forwarded-headers configuration).
- The internal entrypoint ports (`8082` for metrics, `8081` for ping)
  are container-internal-only and not exposed via env vars.
- TLS minimum version, cipher list — controlled in
  [`config/traefik/dynamic/tls.yml`](../config/traefik/dynamic/tls.yml),
  not in `.env`. See [`tls-and-certificates.md`](tls-and-certificates.md).
