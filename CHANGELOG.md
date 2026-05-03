## [0.1.1](https://github.com/bauer-group/CS-Traefik/compare/v0.1.0...v0.1.1) (2026-05-03)

### 🐛 Bug Fixes

* **rate-limit:** raised baseline + added permissive variant for CGNAT ([19189be](https://github.com/bauer-group/CS-Traefik/commit/19189be7c072643133400c985fd0254b1c7c475d))

## [0.1.0](https://github.com/bauer-group/CS-Traefik/compare/v0.0.0...v0.1.0) (2026-05-03)

### 🚀 Features

* **acme:** reordered LE challenges + activated DNS-01 with all providers ([9e77357](https://github.com/bauer-group/CS-Traefik/commit/9e7735711297c868ec28089880a1500be695f06a))
* added CS-Traefik stack (Traefik v3.6 + observability) ([dd6c540](https://github.com/bauer-group/CS-Traefik/commit/dd6c5406a3320c72041d69f5e49734ad93089bc4))
* re-added resource caps on helpers (asymmetric: Traefik uncapped) ([1c8b136](https://github.com/bauer-group/CS-Traefik/commit/1c8b13667c54583f6afffdad4131249fe847ea3a))

### 🐛 Bug Fixes

* enabled non-blocking json-file logging on every service ([75ce366](https://github.com/bauer-group/CS-Traefik/commit/75ce36687d9bcd9d84bb0d6f08773b19c611fc2c))
* removed all deploy.resources.limits (latent bottleneck on edge proxy) ([400300a](https://github.com/bauer-group/CS-Traefik/commit/400300a7e0eed97ca195b027b02c4803a3b55475))
* restored legacy compat (entrypoints, surface, TLS defaults) ([8a16a31](https://github.com/bauer-group/CS-Traefik/commit/8a16a3143d0844feb76fd9b60674f7545fddd8f1))

# Changelog

All notable changes to CS-Traefik are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

* Initial release of the modernised Traefik stack — drop-in successor
  to the legacy v2.x EDGEPROXY setup at `Z Docker Images/Traefik
  Reverse Proxy`. Network/entrypoint/resolver naming preserved so
  existing app stacks keep working without modification.

* **Traefik v3.6** (current) with HTTP/3, structured JSON logs.

* **Compose Profiles** for opt-in features:
  * `core` (default) — Traefik only.
  * `monitoring` — Prometheus, Grafana, Loki, Promtail, Alertmanager,
    node-exporter, cAdvisor with pre-provisioned dashboards.
  * `auto-update` — Watchtower with rolling restart and weekly schedule.

* **Central management script** `traefik.sh` (start/stop/status/logs/
  update/restart/setup/deploy/validate/backup/destroy).

* **Unified `install.sh`** — single mode-aware script that handles BOTH
  the one-line bootstrap (`curl | sudo bash`) AND local re-configuration
  (`./install.sh` runs the .env wizard against an existing checkout).
  No separate setup script.

* **Drop-in legacy compatibility**:
  * Public network: `EDGEPROXY` (default, overridable).
  * Entrypoints: `web` (port 80) and `web-secure` (port 443) — *with
    hyphen*, identical to the legacy stack so existing app
    `entrypoints=web-secure` labels keep working.
  * Default cert resolver: `letsencrypt` (TLS-ALPN-01).
  * Global HTTP→HTTPS redirect at the entry-point level.

* **Hardened admin access on the dedicated `api` entrypoint** — Traefik
  dashboard, Grafana, Prometheus, and Alertmanager are reached at path
  prefixes (`/dashboard`, `/grafana`, `/prometheus`, `/alertmanager`)
  on `127.0.0.1:9090` by default. Three modes: localhost-only
  (default), LAN-accessible, or dedicated public FQDN over HTTPS.
  BasicAuth + IP whitelist always enforced.

* **Atomic, opt-in middleware library** in `dynamic/middlewares.yml` —
  apps choose what they need (HSTS, frame-deny, content-type-nosniff,
  permissions-policy, rate-limits, compression, ...). The proxy imposes
  NO policy on app traffic by default; only `X-Solution-Provider:
  BAUER GROUP` is added by the optional `bg-provider` middleware.

* **TLS compatibility-first defaults** — minimum TLS 1.1 (not 1.2 / not
  1.3) with broad cipher list including legacy CBC and RSA suites.
  Old smartphones and feature phones in emerging markets keep working.
  Stricter `modern@file` (TLS 1.3 only) and `intermediate@file` (TLS
  1.2 + AEAD) options available for sensitive routes via per-router
  `tls.options` label.

* **Four Let's Encrypt resolvers** pre-wired with the BAUER GROUP
  challenge priority **HTTP-01 → TLS-ALPN-01 → DNS-01**:
  * `letsencrypt` — HTTP-01 (DEFAULT, universal, RFC 8555 MUST).
  * `letsencrypt-tls` — TLS-ALPN-01 (fallback when port 80 is fronted).
  * `letsencrypt-dns` — DNS-01 (wildcards, firewalled hosts), provider
    parameterised at runtime via `LETSENCRYPT_DNS_PROVIDER` in `.env`.
  * `letsencrypt-staging` — HTTP-01 against the ACME staging endpoint.

* **DNS-01 active out of the box** with credentials for every common
  provider pre-wired through `docker-compose.yml`: Cloudflare, AWS
  Route 53, Google Cloud DNS, Azure DNS, Hetzner, IONOS, Netcup, INWX,
  Hosting.de, DigitalOcean, Linode, Vultr, OVH, Gandi v5, DNSimple,
  Namecheap, GoDaddy, DNSPod / Tencent Cloud, Scaleway, DuckDNS,
  Designate (OpenStack), Scaleway, ACME-DNS, RFC 2136, and the generic
  `exec` hook for custom shell scripts. Providers not in the pre-wired
  set work too — just add their env vars to `.env`.

* **ACME storage directory renamed** `config/certs/acme/` →
  `config/certs/letsencrypt/` and similarly under `${DATA_DIRECTORY}`.
  Clearer name, single source of truth (the storage holds a
  Let's-Encrypt-specific account + cert state, not a generic ACME-X
  payload).

* **Bring-your-own certificates** (corporate CA, wildcards) supported
  side-by-side via `config/certs/static/` + `dynamic/tls.yml`.

* **Custom file-provider routes** for the 1% of cases that aren't in
  Docker labels — drop your own `*.yml` into
  `config/traefik/dynamic/`. Starter template at
  `dynamic/example-routes.yml.disabled` (rename to `*.yml` to
  activate).

* **Pre-built Grafana dashboards** for the EDGEPROXY overview, Docker
  containers, and a Loki-backed logs explorer.

* **Pre-configured Prometheus alert rules** for host CPU/mem/disk,
  container OOM/throttle, Traefik 5xx spikes, and TLS cert expiry.
  Alertmanager with inhibition + Slack/email-ready receiver stub.

* **Hardened containers**: drop `ALL` capabilities, `no-new-privileges`,
  non-root users (Prometheus 65534, Grafana 472, Loki 10001),
  read-only Docker socket on Traefik. Healthchecks on every service.
  Structured JSON logs, container-level rotation (50m × 5).

* **Asymmetric resource-limit policy** -- Traefik uncapped, helpers
  capped with realistic defaults:
  * **Traefik**: NO `deploy.resources.limits`. Capping the edge proxy
    triggers Linux CFS throttling under load (100ms freezes
    manifesting as 502s / timeouts). Override via
    `docker-compose.override.yml` only when explicitly needed.
  * **Helpers** (Prometheus, Grafana, Loki, Promtail, Alertmanager,
    node-exporter, cAdvisor, Watchtower): capped with headroom-y
    defaults sized for typical BG single-host deployments. Caps
    protect the host against runaway scenarios (cardinality
    explosion, plugin memory leak, ingestion spike, container
    churn, ...).
  * Helper caps are SAFE because the `mode: non-blocking` json-file
    driver decouples log writes from the application -- a throttled
    or OOM'd helper cannot cascade into Traefik request handling.
    Worst case is a metric / log gap until restart.
  * All values tunable via `*_CPU_LIMIT` / `*_MEMORY_LIMIT` in `.env`.

* **`mode: non-blocking` json-file driver on every service** with a 4 MB
  per-container ring buffer (`LOG_MAX_BUFFER_SIZE`). CRITICAL
  guarantee: a stalled Loki / Promtail / log shipper CANNOT cascade
  into Traefik request handling. When the ring buffer fills, log lines
  are dropped instead of blocking the application's stdout writes.
  Configured once via a YAML anchor (`x-logging: &default-logging`)
  and referenced from every service for single-source-of-truth.
