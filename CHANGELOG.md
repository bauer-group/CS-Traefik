# Changelog

All notable changes to CS-Traefik are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

* Initial release of the modernised Traefik stack (replaces the legacy v2.x
  EDGEPROXY setup at `Z Docker Images/Traefik Reverse Proxy`).
* **Traefik v3.6** (current) with HTTP/3, native OpenTelemetry, and modern routing.
* **Compose Profiles** for opt-in features:
  * `core` (default) — Traefik only.
  * `monitoring` — Prometheus, Grafana, Loki, Promtail, Alertmanager,
    node-exporter, cAdvisor with pre-provisioned dashboards.
  * `auto-update` — Watchtower with rolling restart and weekly schedule.
* **Central management script** `traefik.sh` (start/stop/status/logs/update/
  restart/setup/deploy/backup/restore/destroy).
* **Unified `install.sh`** — single mode-aware script that handles BOTH the
  one-line bootstrap (`curl | sudo bash` clones the repo, installs Docker,
  re-execs from the clone) AND local re-configuration (`./install.sh` runs
  the .env wizard against an existing checkout). No separate setup script.
* **EDGEPROXY** as default network name (`EDGEPROXY` external, `EDGEPROXY-internal`
  for monitoring), overridable via `.env`.
* **Let's Encrypt + manual certificate** support side-by-side.
* **Hardened dashboard access**: BasicAuth + IP whitelist + rate-limit on a
  dedicated HTTPS-only subdomain (no path-prefix exposure on port 80/443).
* **Pre-built Grafana dashboards** for Traefik 3, Node, cAdvisor, Loki Logs,
  Docker, and a custom CS-Traefik overview.
* **Modern security headers** (HSTS preload, frame-deny, content-type-nosniff,
  referrer-policy, permissions-policy, CSP-ready).
* **Resource limits, healthchecks, and structured JSON logs** on every service.
