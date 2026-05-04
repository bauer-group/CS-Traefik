# CS-Traefik

> **BAUER GROUP** modern Traefik v3 reverse-proxy stack
> Today, Tomorrow, Together — Building Better Software Together

A drop-in successor to the legacy `EDGEPROXY` Traefik v2 stack. Same
network contract (`EDGEPROXY` external bridge), same entrypoint names,
same resolver names — modern internals, better defaults, no surprise
behaviour for existing app stacks.

For deep documentation see [`docs/`](docs/).

## Highlights

- **Traefik v3.6** (current LTS) with HTTP/3 (QUIC) and structured
  JSON logs.
- **Drop-in compatible** with the legacy v2.x EDGEPROXY stack: network
  name `EDGEPROXY`, entrypoints `web` + `web-secure`, default cert
  resolver `letsencrypt`. Existing app stacks attach without
  modification — see
  [`docs/operations/migration-from-v2.md`](docs/operations/migration-from-v2.md).
- **Hardened admin access**: dedicated `api` entrypoint on
  `127.0.0.1:9090` by default. Three modes: localhost-only / LAN /
  public FQDN over HTTPS. BasicAuth + IP whitelist always enforced.
  See [`docs/admin-access.md`](docs/admin-access.md).
- **Compose Profiles** — opt in to what you actually need:
  - `core` (default) — Traefik only.
  - `monitoring` — Prometheus, Grafana, Loki, Promtail, Alertmanager,
    node-exporter, cAdvisor with pre-provisioned dashboards.
  - `auto-update` — Watchtower with rolling restart, weekly cron.
- **Smart defaults**: TLS 1.1+ (mobile-friendly), CGNAT-tolerant
  rate-limits (5000 req/s baseline), `respondingTimeouts=0s` (long
  uploads work), non-blocking json-file logging (Loki failures cannot
  cascade into Traefik request handling), per-router HTTP→HTTPS
  redirect (apps decide).
- **Atomic, opt-in middleware library**: HSTS, CORS, rate-limits,
  retry, circuit-breaker, forward-auth (Authelia / Authentik), www
  redirects, body-size caps. Plus pre-composed chains
  (`hardened-public`, `hardened-api`, `s3-streaming`, `hardened-login`).
  See [`docs/middlewares.md`](docs/middlewares.md).
- **`X-Solution-Provider: BAUER GROUP`** header is **always-on**
  (entrypoint-level middleware, not opt-out-able). Compliance / branding
  default for the whole estate.
- **Full DNS-01 wildcard support** with 24+ pre-wired providers
  (Cloudflare, AWS Route 53, Azure, Hetzner, IONOS, Netcup, INWX, ...).
  See [`docs/tls-and-certificates.md`](docs/tls-and-certificates.md).
- **IPv4 + IPv6 dual-stack** by default — every public port has both
  bindings.
- **Hardened containers**: drop ALL capabilities, non-root users,
  read-only Docker socket, helper resource caps (Traefik intentionally
  uncapped to avoid CFS-throttling on the request path).

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | sudo bash
```

This installs prerequisites (Docker if absent), clones the repo to
`/opt/edgeproxy`, runs the interactive setup wizard, and starts the
stack. Non-interactive: append `-s -- --yes`.

For manual install / advanced flags, see
[`docs/installation.md`](docs/installation.md).

## Daily operations

```text
sudo ./traefik.sh start         # bring up the active profile mix
sudo ./traefik.sh stop          # stop containers (volumes preserved)
sudo ./traefik.sh restart       # restart all running services
sudo ./traefik.sh status        # ps + resource usage
sudo ./traefik.sh logs          # tail logs from the whole stack
sudo ./traefik.sh logs traefik  # tail one service

sudo ./traefik.sh update        # pull newer Docker images
sudo ./traefik.sh deploy        # pull newer scripts/configs from git
sudo ./traefik.sh setup         # re-run the .env wizard
sudo ./traefik.sh validate      # syntax-check compose + traefik.yml
sudo ./traefik.sh backup        # tar.gz of .env + config + ACME + DBs
sudo ./traefik.sh destroy       # tear down (volumes go; bind data stays)

sudo ./install.sh --reconfigure # equivalent: re-run the wizard
sudo ./install.sh --help        # all installer flags

sudo ./traefik.sh help          # full reference
```

## Connecting your service stacks

App stacks join the `EDGEPROXY` network as **external** and use
standard Traefik labels:

```yaml
services:
  myapp:
    image: ...
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=EDGEPROXY"

      # HTTP -> HTTPS redirect (per-router)
      - "traefik.http.routers.myapp-http.rule=Host(`app.example.com`)"
      - "traefik.http.routers.myapp-http.entrypoints=web"
      - "traefik.http.routers.myapp-http.middlewares=https-redirect@file"

      # HTTPS router
      - "traefik.http.routers.myapp-https.rule=Host(`app.example.com`)"
      - "traefik.http.routers.myapp-https.entrypoints=web-secure"
      - "traefik.http.routers.myapp-https.tls=true"
      - "traefik.http.routers.myapp-https.tls.certresolver=letsencrypt"
      - "traefik.http.routers.myapp-https.service=myapp"

      - "traefik.http.services.myapp.loadbalancer.server.port=8080"
    networks:
      - proxy

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-EDGEPROXY}
```

The Traefik entrypoint is named `web-secure` (with hyphen) — same as
the legacy stack. The `${STACK_NAME}-redirect-to-secure` middleware
pattern from existing compose files **continues to work** since each
app defines its own redirect middleware.

## Documentation

| Topic | Doc |
| --- | --- |
| Detailed installation | [`docs/installation.md`](docs/installation.md) |
| `.env` reference | [`docs/configuration.md`](docs/configuration.md) |
| Compose profiles | [`docs/profiles.md`](docs/profiles.md) |
| Network layout (EDGEPROXY + EDGEPROXY-INTERNAL, IPv4/IPv6) | [`docs/networking.md`](docs/networking.md) |
| TLS, Let's Encrypt, DNS-01 providers, manual certs | [`docs/tls-and-certificates.md`](docs/tls-and-certificates.md) |
| Admin access (3 modes) | [`docs/admin-access.md`](docs/admin-access.md) |
| Middleware catalog | [`docs/middlewares.md`](docs/middlewares.md) |
| Custom file-provider routes | [`docs/custom-config.md`](docs/custom-config.md) |
| Observability (Prometheus / Grafana / Loki / Alertmanager) | [`docs/monitoring.md`](docs/monitoring.md) |
| **Examples** | |
| Basic web app | [`docs/examples/basic-webapp.md`](docs/examples/basic-webapp.md) |
| MinIO / S3 streaming | [`docs/examples/minio-s3.md`](docs/examples/minio-s3.md) |
| API with rate-limit + CORS | [`docs/examples/api-with-rate-limit.md`](docs/examples/api-with-rate-limit.md) |
| Wildcard cert via Cloudflare DNS-01 | [`docs/examples/wildcard-cert-cloudflare.md`](docs/examples/wildcard-cert-cloudflare.md) |
| Forward-auth via Authelia (SSO) | [`docs/examples/forward-auth-authelia.md`](docs/examples/forward-auth-authelia.md) |
| Routing to an on-prem VM | [`docs/examples/on-prem-vm-via-file-provider.md`](docs/examples/on-prem-vm-via-file-provider.md) |
| **Operations** | |
| Migration from legacy v2.x | [`docs/operations/migration-from-v2.md`](docs/operations/migration-from-v2.md) |
| Troubleshooting (502, ACME, dashboard 404, ...) | [`docs/operations/troubleshooting.md`](docs/operations/troubleshooting.md) |
| Backup & restore | [`docs/operations/backup-restore.md`](docs/operations/backup-restore.md) |
| Upgrades (`update` vs. `deploy`) | [`docs/operations/upgrades.md`](docs/operations/upgrades.md) |

## Directory layout

```text
CS-Traefik/
├── install.sh                      # one-line installer + local wizard (mode-aware)
├── traefik.sh                      # central management console
├── docker-compose.yml              # core: Traefik
├── docker-compose.monitoring.yml   # profile: monitoring
├── docker-compose.auto-update.yml  # profile: auto-update
├── .env.example                    # every option documented
├── docs/                           # detailed documentation -- start here
└── config/
    ├── traefik/
    │   ├── traefik.yml             # static config (entrypoints, resolvers, providers)
    │   └── dynamic/
    │       ├── middlewares.yml     # atomic opt-in middlewares + chains
    │       ├── tls.yml             # TLS options + manual certs
    │       └── example-routes.yml.disabled  # template for custom file-provider routes
    ├── certs/{static,letsencrypt}/ # bring-your-own + ACME storage
    ├── prometheus/                 # prometheus.yml + alerts.yml
    ├── alertmanager/               # alertmanager.yml
    ├── grafana/
    │   ├── provisioning/{datasources,dashboards}/
    │   └── dashboards/*.json
    ├── loki/loki-config.yml
    └── promtail/promtail-config.yml
```

## License

[MIT](LICENSE) — Copyright © 2026 BAUER GROUP.

Bundled open-source components retain their own licenses. See
[`NOTICE.md`](NOTICE.md).

## Related stacks

- [bauer-group/CS-Coolify](https://github.com/bauer-group/CS-Coolify) —
  same management UX, Coolify self-hosting.
- [bauer-group/CI-GitHubRunner](https://github.com/bauer-group/CI-GitHubRunner) —
  same management UX, ephemeral GitHub runners.
