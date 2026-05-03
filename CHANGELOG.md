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

* **Three Let's Encrypt resolvers** pre-wired (TLS-ALPN-01, HTTP-01,
  staging) selectable per-router via labels. **DNS-01 wildcard
  resolver template documented but inactive** in `traefik.yml` — no
  DNS-provider API integration yet; uncomment and add credentials when
  that's set up.

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
  read-only Docker socket on Traefik. Resource limits + healthchecks
  on every service. Structured JSON logs, container-level rotation
  (50m × 5).
