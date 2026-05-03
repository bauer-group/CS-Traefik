# CS-Traefik

> **BAUER GROUP** modern Traefik v3 reverse-proxy stack
> Today, Tomorrow, Together — Building Better Software Together

A drop-in successor to the legacy `EDGEPROXY` Traefik v2 stack. Same network
contract (`EDGEPROXY` external bridge), but on top of Traefik v3 with a modern
observability stack, profile-driven feature toggles, and a single management
script that mirrors the `runner.sh` / `coolify.sh` UX from sibling repos.

---

## Highlights

- **Traefik v3.6** (current) with HTTP/3 (QUIC), OpenTelemetry-ready, structured JSON logs.
- **Hardened admin access**: dedicated HTTPS subdomain, BasicAuth (bcrypt) +
  IP whitelist + strict rate limit + modern security headers.
- **Compose Profiles** — opt in to what you actually need:
  - `core` (default) — Traefik only.
  - `monitoring` — Prometheus, Grafana, Loki, Promtail, Alertmanager,
    node-exporter, cAdvisor with pre-provisioned dashboards.
  - `auto-update` — Watchtower with rolling restart, weekly cron.
- **Let's Encrypt + manual certificates** side-by-side (TLS-ALPN, HTTP-01,
  DNS-01 for wildcards). Bring your own corporate-CA wildcard? Drop it in
  `config/certs/static/` and reference from `dynamic/tls.yml`.
- **EDGEPROXY** as the default public network (overridable via `.env`),
  with a separate `EDGEPROXY-internal` network for monitoring traffic so
  metrics/logs never traverse the public bridge.
- **Single-shot install**: one curl command bootstraps the whole stack.
- **Atomic updates**: `traefik.sh deploy` for git, `traefik.sh update` for
  images. They are intentionally separate so you can bisect regressions.

---

## Quick start

### One-line install (Linux host with sudo)

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | sudo bash
```

This will:

1. Install missing prerequisites (git, curl, openssl, Docker if absent).
2. Clone the repo to `/opt/edgeproxy`.
3. Run the interactive `.env` wizard (FQDN for the dashboard, Let's Encrypt
   email, profile selection, generated bcrypt admin credentials).
4. Bring the stack up with `traefik.sh start`.

Non-interactive (cloud-init / CI):

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | sudo bash -s -- --yes
```

### Manual install

```bash
git clone https://github.com/bauer-group/CS-Traefik.git /opt/edgeproxy
cd /opt/edgeproxy
sudo ./install.sh                # detects the local checkout, runs the wizard
sudo ./traefik.sh start
```

`install.sh` is mode-aware: piped in from `curl`, it bootstraps from
scratch (clone + setup); invoked from a checkout, it just runs the wizard.
Same script, same flags, both flows.

---

## Daily operations

Everything goes through `traefik.sh`:

```text
sudo ./traefik.sh start         # bring up the active profile mix
sudo ./traefik.sh stop          # stop containers (volumes preserved)
sudo ./traefik.sh restart       # restart all running services
sudo ./traefik.sh status        # ps + resource usage
sudo ./traefik.sh logs          # tail logs from the whole stack
sudo ./traefik.sh logs traefik  # tail one service

sudo ./traefik.sh update        # pull newer Docker images
sudo ./traefik.sh deploy        # pull newer scripts/configs from git
sudo ./traefik.sh setup         # re-run the .env wizard (delegates to install.sh)
sudo ./traefik.sh validate      # syntax-check compose + traefik.yml
sudo ./traefik.sh backup        # tar.gz of .env + config + ACME + DBs
sudo ./traefik.sh destroy       # tear down (volumes go; bind data stays)

sudo ./install.sh --reconfigure # equivalent: re-run the wizard
sudo ./install.sh --help        # all installer flags

sudo ./traefik.sh help          # full reference
```

---

## Profiles (feature toggles)

Profiles are activated in `.env`:

```env
COMPOSE_PROFILES=                       # core only (Traefik)
COMPOSE_PROFILES=monitoring             # core + observability
COMPOSE_PROFILES=monitoring,auto-update # everything
```

`traefik.sh` reads this variable, loads the right `docker-compose.*.yml`
overlays, and passes the right `--profile` flags. No need to remember
multi-file invocations.

| Profile        | What it adds                                                  |
| -------------- | ------------------------------------------------------------- |
| `core`         | Traefik only (default).                                       |
| `monitoring`   | Prometheus + Grafana + Loki + Promtail + Alertmanager +       |
|                | node-exporter + cAdvisor + pre-provisioned dashboards.        |
| `auto-update`  | Watchtower (rolling restart, weekly cron, label-opt-in).      |

---

## Endpoints

After `start`, services are exposed on:

| Service         | URL pattern                              | Auth                          |
| --------------- | ---------------------------------------- | ----------------------------- |
| Apps (yours)    | `https://<your-app>.<your-domain>`       | per-app                       |
| Traefik         | `https://${DASHBOARD_HOST}`              | IP whitelist + BasicAuth      |
| Grafana¹        | `https://${GRAFANA_HOST}`                | IP whitelist + Grafana login  |
| Prometheus¹     | `https://${PROMETHEUS_HOST}`             | IP whitelist + BasicAuth      |
| Alertmanager¹   | `https://${ALERTMANAGER_HOST}`           | IP whitelist + BasicAuth      |

¹ Only when the `monitoring` profile is active.

All admin surfaces are HTTPS-only, behind the same BasicAuth + IP whitelist
chain, with strict rate limiting (10 req/s) and modern security headers.

---

## Connecting your service stacks

Service stacks join the `EDGEPROXY` network as **external**:

```yaml
# any-service/docker-compose.yml
services:
  myapp:
    image: ...
    labels:
      traefik.enable: "true"
      traefik.docker.network: "EDGEPROXY"
      traefik.http.routers.myapp.rule: "Host(`app.example.com`)"
      traefik.http.routers.myapp.entrypoints: "websecure"
      traefik.http.routers.myapp.tls.certresolver: "letsencrypt"
      # apply the public-app middleware chain from CS-Traefik:
      traefik.http.routers.myapp.middlewares: "public-chain@file"
      traefik.http.services.myapp.loadbalancer.server.port: "8080"
    networks:
      - edgeproxy

networks:
  edgeproxy:
    external: true
    name: EDGEPROXY
```

The `public-chain@file` middleware is provided by CS-Traefik and gives you
HSTS, frame-deny, content-type-nosniff, compression, and a 1000 req/s baseline
rate limit.

---

## TLS

### Let's Encrypt (default)

`LETSENCRYPT_EMAIL` is the only required value. Three resolvers are
pre-configured in `config/traefik/traefik.yml`:

- `letsencrypt` — production ACME with **TLS-ALPN-01** (default; works on
  port 443).
- `letsencrypt-http` — production ACME with **HTTP-01** (works on port 80).
- `letsencrypt-staging` — ACME staging endpoint for testing.

Pick a resolver per router via `traefik.http.routers.X.tls.certresolver=`.

#### Wildcards (DNS-01)

For `*.example.com` style certificates you need DNS-01. Uncomment the
`letsencrypt-dns` resolver in `traefik.yml`, set the provider, and pass
the credentials as additional env vars in `.env`. Reference:
[Traefik DNS providers](https://doc.traefik.io/traefik/https/acme/#providers).

```env
# .env additions for Cloudflare wildcards
LETSENCRYPT_DNS_PROVIDER=cloudflare
CF_DNS_API_TOKEN=...
```

### Manual certificates

Drop your `*.crt` and `*.key` into `config/certs/static/` and reference
them from `config/traefik/dynamic/tls.yml`:

```yaml
# config/traefik/dynamic/tls.yml
tls:
  certificates:
    - certFile: /etc/traefik/certs/static/wildcard.bauer-group.com.crt
      keyFile:  /etc/traefik/certs/static/wildcard.bauer-group.com.key
```

Reload picks up the change automatically (file provider watches the
directory).

---

## Monitoring

Activate the profile in `.env`:

```env
COMPOSE_PROFILES=monitoring
```

then `sudo ./traefik.sh restart`. You get:

- **Prometheus** at `https://${PROMETHEUS_HOST}` — scraping Traefik
  metrics, host metrics (node-exporter), container metrics (cAdvisor),
  and self-metrics from Loki/Grafana/Alertmanager.
- **Grafana** at `https://${GRAFANA_HOST}` with three pre-provisioned
  dashboards:
  - *EDGEPROXY — Overview*: single pane (request rate, error %, latency,
    cert expiry, host CPU/mem/disk, recent 5xx logs).
  - *EDGEPROXY — Containers*: per-container CPU/memory/network/throttle.
  - *EDGEPROXY — Logs Explorer*: Loki-backed log search across the stack.
- **Loki + Promtail** for log aggregation (Docker JSON logs + Traefik
  access/server file logs).
- **Alertmanager** at `https://${ALERTMANAGER_HOST}` — pre-configured
  rules for high CPU, low disk, container OOM, Traefik 5xx spikes, and
  TLS expiry. Plug a Slack/email receiver into `config/alertmanager/alertmanager.yml`.

Want the upstream community dashboards in addition? Import via Grafana UI:

| Dashboard                | Grafana.com ID |
| ------------------------ | -------------- |
| Node Exporter Full       | 1860           |
| cAdvisor / Docker        | 14282          |
| Traefik 3 Official       | 17347          |
| Loki Logs / App          | 13639          |

---

## Auto-update

Activate the profile in `.env`:

```env
COMPOSE_PROFILES=monitoring,auto-update
```

Watchtower runs weekly (Sat 03:00 by default), updates only services with
the `com.centurylinklabs.watchtower.enable=true` label (every CS-Traefik
service), uses rolling restart, and prunes old images. Customise the
schedule via `WATCHTOWER_SCHEDULE` (six-field cron).

---

## Directory layout

```text
CS-Traefik/
├── install.sh                     # one-line installer (curl|bash)
├── traefik.sh                     # central management console
├── docker-compose.yml             # core: Traefik
├── docker-compose.monitoring.yml  # profile: monitoring
├── docker-compose.auto-update.yml # profile: auto-update
├── .env.example                   # every option documented
├── config/
│   ├── traefik/
│   │   ├── traefik.yml            # static config
│   │   └── dynamic/
│   │       ├── middlewares.yml    # security headers, chains
│   │       └── tls.yml            # TLS options + manual certs
│   ├── certs/{static,acme}/       # bring-your-own + ACME storage
│   ├── prometheus/                # prometheus.yml + alerts.yml
│   ├── alertmanager/              # alertmanager.yml
│   ├── grafana/
│   │   ├── provisioning/{datasources,dashboards}/
│   │   └── dashboards/*.json
│   ├── loki/loki-config.yml
│   └── promtail/promtail-config.yml
└── (no scripts/ folder -- everything lives in install.sh / traefik.sh)
```

---

## Configuration reference

Every value is documented in [`.env.example`](.env.example). The wizard
covers the values you have to pick (FQDNs, passwords, profile mix). The
rest defaults sensibly.

Resource limits, log rotation sizes, retention windows, and image tag pins
are all overridable in `.env`.

---

## Migration from the legacy stack

The old stack at `Z Docker Images/Traefik Reverse Proxy` used:

- Traefik **v2.11** — replaced by **v3.x** (LTS).
- Path-prefix admin routing (`/dashboard`, `/grafana`) — replaced by
  dedicated subdomains with HTTPS-only access.
- HostRegexp v2 syntax with named groups — replaced by Traefik v3 routing
  rules (Go regex if needed).
- Two networks (`EDGEPROXY` + `EDGEPROXY_INTERNAL`) — kept identical
  (`EDGEPROXY` + `EDGEPROXY-internal`, hyphen instead of underscore to
  match the modern naming convention; legacy `EDGEPROXY` external network
  name is preserved).

Migration steps:

1. Stand up CS-Traefik on a different host (or different ports) for soak.
2. DNS-cutover dashboard / grafana to the new subdomains.
3. Re-label your existing service stacks: drop the path-prefix routing,
   add per-host routers, point at `EDGEPROXY` (already running).
4. Decommission the v2 stack once everything is migrated.

The data is fully portable — `traefik.sh backup` from the old stack is
not needed; ACME storage will simply re-issue new Let's Encrypt certs on
the new edge.

---

## Security

- **Admin surfaces** are HTTPS-only, on dedicated subdomains, behind
  IP whitelist + BasicAuth + 10 req/s rate limit + modern headers.
- **Public surfaces** get HSTS preload-eligible, frame-deny, content-type-
  nosniff, referrer-policy strict-origin-when-cross-origin, permissions-
  policy denying camera/mic/geolocation/payment, and Server header
  scrubbing.
- **Containers** drop `ALL` capabilities and re-add only what's needed
  (NET_BIND_SERVICE for Traefik on 80/443; SYS_TIME for node-exporter
  clock skew). `no-new-privileges:true` everywhere.
- **Non-root users** for Prometheus (65534), Grafana (472), Loki (10001).
- **Read-only docker socket** mount for Traefik. (Move to
  `tecnativa/docker-socket-proxy` if you want extra defence.)
- **No secrets in code** — `.env` is gitignored and chmod 600 by the
  wizard.

Future hardening (not enabled by default; PR-ready):

- Forward-auth via Authelia or Authentik for SSO across all admin
  surfaces.
- mTLS for backend-only routers (TLS options block in `dynamic/tls.yml`
  has a commented-out template).
- WAF in front (Coraza middleware plugin).

---

## Backup / restore

```bash
sudo ./traefik.sh backup
# -> /opt/edgeproxy/backups/edgeproxy_YYYYMMDD_HHMMSS.tar.gz
```

Archive contains: `.env`, the entire `config/`, ACME certificate JSON,
Grafana SQLite DB, Prometheus blocks (WAL excluded), Alertmanager state.

Restore is a manual `tar -xzf` into the same `DATA_DIRECTORY` plus
`docker compose up -d`.

---

## Troubleshooting

```bash
sudo ./traefik.sh validate     # compose + traefik.yml syntax check
sudo ./traefik.sh logs traefik # follow Traefik
sudo docker exec edgeproxy-traefik traefik version

# ACME debug
sudo docker exec edgeproxy-traefik cat /etc/traefik/certs/acme/letsencrypt.json | jq .
```

If Let's Encrypt rate-limits you during testing, switch the resolver to
`letsencrypt-staging` (per-router via labels, or globally in
`traefik.yml`).

---

## License

[MIT](LICENSE) — Copyright © 2026 BAUER GROUP.

Bundled open-source components retain their own licenses. See [`NOTICE.md`](NOTICE.md).

---

## Related stacks

- [bauer-group/CS-Coolify](https://github.com/bauer-group/CS-Coolify) —
  same management UX, Coolify self-hosting.
- [bauer-group/CI-GitHubRunner](https://github.com/bauer-group/CI-GitHubRunner) —
  same management UX, ephemeral GitHub runners.
