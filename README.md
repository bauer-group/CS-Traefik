# CS-Traefik

> **BAUER GROUP** modern Traefik v3 reverse-proxy stack
> Today, Tomorrow, Together — Building Better Software Together

A drop-in successor to the legacy `EDGEPROXY` Traefik v2 stack. Same network
contract, same entrypoint names, same resolver names — modern internals,
better defaults, no surprise behaviour for existing app stacks.

---

## Highlights

- **Traefik v3.6** (current) with HTTP/3 (QUIC), structured JSON logs.
- **Drop-in compatible** with the legacy EDGEPROXY stack:
  - Public network: `EDGEPROXY` (overridable, IPv4 + IPv6).
  - Entrypoints: `web` (80) and `web-secure` (443) — *with hyphen*, like
    legacy. Existing app `entrypoints=web-secure` labels keep working.
  - Default cert resolver: `letsencrypt` (TLS-ALPN-01).
  - HTTP→HTTPS redirect at the entry-point level.
- **Hardened admin access**: dedicated `api` entrypoint on
  `127.0.0.1:9090` by default — Traefik dashboard, Grafana, Prometheus,
  and Alertmanager are reachable via path-prefix routing
  (`/dashboard`, `/grafana`, `/prometheus`, `/alertmanager`) with
  BasicAuth + IP whitelist always enforced. **Not on port 443**, low
  attack surface.
- **Three access modes** for admin UIs: localhost-only (default),
  LAN-accessible, or dedicated public FQDN over HTTPS.
- **Compose Profiles** — opt in to what you actually need:
  - **`core` (default)** — Traefik only.
  - `monitoring` — Prometheus, Grafana, Loki, Promtail, Alertmanager,
    node-exporter, cAdvisor with pre-provisioned dashboards.
  - `auto-update` — Watchtower with rolling restart, weekly cron.
- **No imposed middleware policies** on app traffic. Only the
  `X-Solution-Provider: BAUER GROUP` header is added by default. HSTS,
  Permissions-Policy, frame-deny, rate-limits etc. ship as **atomic
  opt-in middlewares** apps choose individually.
- **TLS compatibility-first**: default minVersion = **TLS 1.1**, broad
  cipher list including legacy CBC and RSA suites. Old smartphones,
  feature phones, and KaiOS clients keep working. `modern@file` (TLS 1.3
  only) and `intermediate@file` available for sensitive routes.
- **Three Let's Encrypt resolvers** pre-wired (TLS-ALPN-01, HTTP-01,
  staging). DNS-01 wildcard template **prepared but inactive** — add
  provider credentials when you're ready.
- **Bring-your-own certificates** (corporate CA, wildcards). Drop into
  `config/certs/static/` and reference from `dynamic/tls.yml`.
- **Custom YAML config** for the 1% of routes that aren't in Docker
  labels (VMs, on-prem, external SaaS). Drop `*.yml` into
  `config/traefik/dynamic/` — Traefik picks them up live.
- **Single-shot install**: one `curl|bash` clones, configures, starts.
- **Atomic updates**: `traefik.sh deploy` for git, `traefik.sh update`
  for images. Separate so you can bisect regressions.

---

## Quick start

### One-line install (Linux host with sudo)

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | sudo bash
```

This will:

1. Install missing prerequisites (git, curl, openssl, Docker if absent).
2. Clone the repo to `/opt/edgeproxy`.
3. Run the interactive setup wizard.
4. Bring the stack up with `traefik.sh start`.

Non-interactive (cloud-init / CI):

```bash
curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | sudo bash -s -- --yes
```

### Manual install

```bash
git clone https://github.com/bauer-group/CS-Traefik.git /opt/edgeproxy
cd /opt/edgeproxy
sudo ./install.sh                # detects local checkout, runs the wizard
sudo ./traefik.sh start
```

`install.sh` is mode-aware: piped from `curl`, it bootstraps from
scratch; invoked from a checkout, it just runs the wizard. Same script,
same flags, both flows.

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
COMPOSE_PROFILES=                       # core only (DEFAULT)
COMPOSE_PROFILES=monitoring             # core + observability
COMPOSE_PROFILES=monitoring,auto-update # everything
```

`traefik.sh` reads this variable, loads the right `docker-compose.*.yml`
overlays, and passes the right `--profile` flags. No need to remember
multi-file invocations.

| Profile        | What it adds                                                  |
| -------------- | ------------------------------------------------------------- |
| **`core`**     | Traefik only (DEFAULT).                                       |
| `monitoring`   | Prometheus + Grafana + Loki + Promtail + Alertmanager +       |
|                | node-exporter + cAdvisor + pre-provisioned dashboards.        |
| `auto-update`  | Watchtower (rolling restart, weekly cron, label-opt-in).      |

---

## Admin access

The Traefik dashboard, Grafana, Prometheus, and Alertmanager all live
behind the dedicated `api` entrypoint at path prefixes — never on the
public 443 port unless you explicitly configure it.

### Mode 1 — Localhost only (default, most secure)

`API_BIND=127.0.0.1` (default). The api entrypoint is reachable only
from the Docker host's loopback. Connect via SSH-tunnel:

```bash
ssh -L 9090:127.0.0.1:9090 user@server

# then in your browser:
open http://127.0.0.1:9090/dashboard/
                          /grafana/
                          /prometheus/
                          /alertmanager/
```

BasicAuth (`API_USERS`) + IP whitelist (`API_WHITELIST`) are always
enforced — defence-in-depth even on the loopback.

### Mode 2 — LAN accessible

`API_BIND=0.0.0.0`. Reachable on `http://<host-ip>:9090/...` from any
network the Docker host is on. BasicAuth + IP whitelist still enforced.
No TLS on this entrypoint by default — fine for trusted LANs / VPN.

### Mode 3 — Public FQDN over HTTPS

Set `API_HOST=admin.bauer-group.com` (a hostname *that hosts no app*).
A second router activates on `web-secure` with Let's Encrypt TLS,
BasicAuth, and IP whitelist:

```text
https://admin.bauer-group.com/dashboard/
                             /grafana/
                             /prometheus/
                             /alertmanager/
```

You can combine: localhost (mode 1) is always available; mode 3
*adds* the public FQDN on top.

---

## Connecting your service stacks

Service stacks join the `EDGEPROXY` network as **external**. Identical
labelling to the legacy stack:

```yaml
# any-service/docker-compose.yml
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
pattern from your existing compose files **continues to work** since
each app defines its own redirect middleware.

### Optional middleware hardening

Apps choose what they need from `dynamic/middlewares.yml`:

```yaml
# Apply HSTS + frame-deny + content-type-nosniff + the BG header
- "traefik.http.routers.myapp-https.middlewares=hardened-public@file"

# Or compose your own:
- "traefik.http.routers.myapp-https.middlewares=hsts@file,nosniff@file,bg-provider@file"

# Or none at all (the proxy will not impose any policy on your traffic)
```

Available atomic middlewares: `bg-provider`, `compression`,
`strip-auth`, `https-redirect`, `hsts`, `hsts-mild`, `frame-deny`,
`frame-sameorigin`, `nosniff`, `referrer-strict`, `referrer-noreferrer`,
`permissions-deny`, `rate-limit`, `rate-limit-strict`, `server-scrub`.

Pre-composed example chains: `hardened-public`, `hardened-api`.

---

## TLS

### Default — compatibility-first

`tls.options.default` (config/traefik/dynamic/tls.yml):

- Min version: **TLS 1.1** — accommodates older Android, KaiOS, and
  feature-phone WebViews common in emerging markets.
- Wide cipher list: TLS 1.3 (auto), modern AEAD, legacy CBC, plus RSA
  key-exchange for very old clients.
- TLS 1.0 is intentionally NOT enabled (POODLE / BEAST / SWEET32).

### Stricter options for sensitive routes

```yaml
# admin / payment / PCI workloads
traefik.http.routers.checkout-https.tls.options=modern@file        # TLS 1.3 only
traefik.http.routers.api-https.tls.options=intermediate@file       # TLS 1.2 minimum, AEAD only
```

### Let's Encrypt

Four resolvers are pre-configured. Pick a resolver per router via
`traefik.http.routers.X.tls.certresolver=...`:

| Resolver               | Challenge   | When to use                                     |
| ---------------------- | ----------- | ----------------------------------------------- |
| `letsencrypt`          | HTTP-01     | **DEFAULT.** Universal compatibility, RFC-MUST. |
| `letsencrypt-tls`      | TLS-ALPN-01 | Fallback when port 80 is fronted/blocked.       |
| `letsencrypt-dns`      | DNS-01      | Wildcards, hosts unreachable from public net.   |
| `letsencrypt-staging`  | HTTP-01     | Initial roll-out testing, no rate-limit pain.   |

Priority order: **HTTP-01 → TLS-ALPN-01 → DNS-01**. HTTP-01 is the
primary because it's the most universal challenge (RFC 8555 marks it
MUST-implement), simplest setup, and works through CDNs/WAFs that
might not expose underlying TLS handshakes. TLS-ALPN-01 is the
fallback for hosts where port 80 isn't usable. DNS-01 is last because
it's the slowest (DNS propagation overhead) — use only when needed.

Both HTTP-01 (port 80) and TLS-ALPN-01 (port 443) challenges are
fully supported and reuse the existing entrypoints — no extra config.

### Wildcards / DNS-01

The DNS-01 resolver is **active and parameterised** — pick a provider
in `.env`:

```env
LETSENCRYPT_DNS_PROVIDER=cloudflare         # any provider Traefik supports
CF_DNS_API_TOKEN=...                         # provider-specific credentials
```

Then reference from any router:

```yaml
traefik.http.routers.foo.tls.certresolver=letsencrypt-dns
traefik.http.routers.foo.tls.domains[0].main=bauer-group.com
traefik.http.routers.foo.tls.domains[0].sans=*.bauer-group.com
```

**Pre-wired provider credentials** in `docker-compose.yml` (you only
need to populate the ones for your chosen provider in `.env`):

| Provider          | Key for `LETSENCRYPT_DNS_PROVIDER` |
| ----------------- | ---------------------------------- |
| Cloudflare        | `cloudflare`                       |
| AWS Route 53      | `route53`                          |
| Google Cloud DNS  | `gcloud`                           |
| Azure DNS         | `azuredns`                         |
| Hetzner DNS       | `hetzner`                          |
| IONOS / 1&1       | `ionos`                            |
| Netcup (DE)       | `netcup`                           |
| INWX (DE)         | `inwx`                             |
| Hosting.de        | `hostingde`                        |
| DigitalOcean      | `digitalocean`                     |
| Linode            | `linode`                           |
| Vultr             | `vultr`                            |
| OVH               | `ovh`                              |
| Gandi v5          | `gandiv5`                          |
| DNSimple          | `dnsimple`                         |
| Namecheap         | `namecheap`                        |
| GoDaddy           | `godaddy`                          |
| DNSPod / Tencent  | `dnspod` / `tencentcloud`          |
| Scaleway          | `scaleway`                         |
| DuckDNS           | `duckdns`                          |
| Designate (OS)    | `designate`                        |
| ACME-DNS (alias)  | `acme-dns`                         |
| RFC 2136 (BIND)   | `rfc2136`                          |
| Generic shell hook| `exec`                             |

The full list of [100+ providers Traefik
supports](https://doc.traefik.io/traefik/https/acme/#providers) all
work — providers not in the table above just need their env vars added
to `.env` (Compose passes the whole `.env` through).

`.env.example` documents the env vars for each pre-wired provider.

### Manual / corporate-CA certificates

Drop `*.crt` + `*.key` into `config/certs/static/`, then list each pair
in `config/traefik/dynamic/tls.yml`:

```yaml
tls:
  certificates:
    - certFile: /etc/traefik/certs/static/wildcard.bauer-group.com.crt
      keyFile:  /etc/traefik/certs/static/wildcard.bauer-group.com.key
      stores:
        - default
```

Reload picks up the change automatically (file provider watches the
directory).

---

## Custom dynamic configuration

For the 1% of routes that aren't in Docker labels (VMs, static IPs,
external SaaS, on-prem appliances), drop your own `*.yml` into
`config/traefik/dynamic/` next to `middlewares.yml` and `tls.yml`.

A starter template lives at
`config/traefik/dynamic/example-routes.yml.disabled`. Rename to `*.yml`
to activate, then edit. Saves are picked up live (file provider has
`watch=true`).

Files ending in `.disabled` are ignored by Traefik (only `.yml` /
`.yaml` extensions are loaded).

---

## Monitoring

Activate the profile in `.env`:

```env
COMPOSE_PROFILES=monitoring
```

then `sudo ./traefik.sh restart`. You get:

- **Prometheus** scraping Traefik metrics, host metrics
  (node-exporter), container metrics (cAdvisor), and self-metrics from
  Loki/Grafana/Alertmanager.
- **Grafana** with three pre-provisioned dashboards (overview,
  containers, logs explorer).
- **Loki + Promtail** for log aggregation (Docker JSON logs + Traefik
  access/server file logs).
- **Alertmanager** with pre-configured rules for high CPU, low disk,
  container OOM, Traefik 5xx spikes, and TLS expiry.

All four UIs reachable via the api entrypoint:

```text
http://127.0.0.1:9090/dashboard/      # Traefik
http://127.0.0.1:9090/grafana/        # Grafana (own login on top of BasicAuth)
http://127.0.0.1:9090/prometheus/     # Prometheus
http://127.0.0.1:9090/alertmanager/   # Alertmanager
```

Want the upstream community dashboards in addition? Import via Grafana
UI:

| Dashboard                | Grafana.com ID |
| ------------------------ | -------------- |
| Node Exporter Full       | 1860           |
| cAdvisor / Docker        | 14282          |
| Traefik 3 Official       | 17347          |
| Loki Logs / App          | 13639          |

---

## Auto-update

Activate the profile:

```env
COMPOSE_PROFILES=monitoring,auto-update
```

Watchtower runs weekly (Sat 03:00 by default), updates only services
labelled `com.centurylinklabs.watchtower.enable=true` (every CS-Traefik
service), uses rolling restart, and prunes old images. Customise via
`WATCHTOWER_SCHEDULE` (six-field cron).

---

## Directory layout

```text
CS-Traefik/
├── install.sh                     # one-line installer + local wizard (mode-aware)
├── traefik.sh                     # central management console
├── docker-compose.yml             # core: Traefik
├── docker-compose.monitoring.yml  # profile: monitoring
├── docker-compose.auto-update.yml # profile: auto-update
├── .env.example                   # every option documented
└── config/
    ├── traefik/
    │   ├── traefik.yml            # static config (entrypoints, resolvers, providers)
    │   └── dynamic/
    │       ├── middlewares.yml             # atomic opt-in middlewares + chains
    │       ├── tls.yml                     # TLS options + manual certs
    │       └── example-routes.yml.disabled # template for custom file-provider routes
    ├── certs/{static,acme}/       # bring-your-own + ACME storage
    ├── prometheus/                # prometheus.yml + alerts.yml
    ├── alertmanager/              # alertmanager.yml
    ├── grafana/
    │   ├── provisioning/{datasources,dashboards}/
    │   └── dashboards/*.json
    ├── loki/loki-config.yml
    └── promtail/promtail-config.yml
```

---

## Migration from the legacy stack

| Concern               | Legacy v2.x stack             | CS-Traefik (this repo)         |
| --------------------- | ----------------------------- | ------------------------------ |
| Traefik version       | v2.11                         | v3.6 LTS                       |
| Public network name   | `EDGEPROXY` (default)         | `EDGEPROXY` (default)          |
| Internal network name | `EDGEPROXY_INTERNAL`          | `EDGEPROXY-internal`           |
| Entrypoints           | `web` + `web-secure`          | `web` + `web-secure`           |
| Default cert resolver | `letsencrypt` (TLS-ALPN-01)   | `letsencrypt` (TLS-ALPN-01)    |
| HTTP→HTTPS redirect   | global at entrypoint          | global at entrypoint           |
| Dashboard exposure    | `:9090` + path-prefix         | `:9090` + path-prefix          |
| Dashboard auth        | BasicAuth + IP whitelist      | BasicAuth + IP whitelist       |
| Monitoring URLs       | `:9090/metrics`, `/grafana`   | `:9090/grafana`, `/prometheus` |

**Existing app `docker-compose.yml` files keep working without
modification.** The reverse-proxy interface (network name, entrypoint
names, resolver names, port assignments) is byte-compatible with the
legacy EDGEPROXY stack.

The internal network name changed from underscore to hyphen
(`EDGEPROXY_INTERNAL` → `EDGEPROXY-internal`) only because the new
stack uses Compose's automatic naming convention. App stacks normally
do not attach to that network — only Traefik and the monitoring stack
use it.

Migration steps:

1. Stand up CS-Traefik on the same host (different ports) or a separate
   one for soak.
2. DNS-cutover happens at the app level — your app stacks already point
   to `Host(\`app.example.com\`)`, so all you do is swap which Traefik
   binary is on the receiving end.
3. ACME storage will simply re-issue new Let's Encrypt certs on the new
   edge.
4. Decommission the v2 stack once migration is complete.

---

## Logging never blocks the application

Every service uses the Docker `json-file` driver in
**`mode: non-blocking`** with a 4 MB ring buffer per container.

What this means in practice: if Loki or Promtail (or whatever log
shipper you bolt on) stalls — even for several minutes — the
application's `write()` to stdout / stderr returns immediately. The
driver drops log lines once the buffer is full, but the **application
keeps serving requests at full speed**.

This breaks the textbook log-pipeline cascade:

```text
Loki slow  ->  Promtail buffers fill  ->  Promtail stops reading
   ->  Docker json-file buffer fills  ->  WITHOUT non-blocking:
                                          stdout write() blocks
                                          ->  Traefik request handler
                                              blocks on access-log write
                                              ->  502s, timeouts
   ->  WITH non-blocking (the default here): log lines dropped,
       Traefik continues serving traffic at full speed.
```

Logs are non-critical. Serving traffic is critical. This is the
right trade-off for an edge proxy.

Tunables in `.env`:

```env
LOG_MAX_BUFFER_SIZE=4m    # per-container ring buffer (≈ 10-50k lines)
LOG_MAX_SIZE=50m          # rotation: max single file size
LOG_MAX_FILE=5            # rotation: max number of rotated files
```

---

## Resource limits

**Asymmetric policy**: Traefik is uncapped, helpers are capped. The
two cases have different risk profiles:

### Traefik — uncapped

The edge proxy is the single hot path for every ingress request.
Capping its CPU triggers Linux CFS throttling — 100 ms freezes that
look like 502s / timeouts to clients even when the host has idle
headroom. There is no shipper or buffer in front of request handling,
so a throttled Traefik directly translates to user-visible latency.

If you really need to cap Traefik (multi-tenant Docker host,
regulatory ceiling, known-bad upstream that floods you), add a
`docker-compose.override.yml` at the repo root — Compose merges it
automatically:

```yaml
# docker-compose.override.yml
services:
  traefik:
    deploy:
      resources:
        limits:
          cpus:   "8"
          memory: 4g
```

This way the limit is visibly your decision, not a hidden default
working against you.

### Helpers — capped, with non-blocking logging as safety net

Prometheus, Grafana, Loki, Promtail, Alertmanager, node-exporter,
cAdvisor, and Watchtower all have realistic resource caps. The
`mode: non-blocking` json-file driver (see [Logging](#logging-never-blocks-the-application))
means a throttled / OOM'd helper **cannot cascade** into Traefik
request handling — worst case is a metric / log gap until the helper
restarts.

Caps protect the host against runaway scenarios:

| Service       | Default cap     | Protects against                            |
| ------------- | --------------- | ------------------------------------------- |
| Prometheus    | 4 CPU / 4 GB    | Cardinality explosion (label leak)          |
| Grafana       | 2 CPU / 1 GB    | Plugin memory leak, dashboard render storm  |
| Loki          | 2 CPU / 2 GB    | Ingestion spike from a misconfigured app    |
| Promtail      | 1 CPU / 512 MB  | Regex storm, parser bug                     |
| Alertmanager  | 1 CPU / 256 MB  | Alert-storm / templating-loop               |
| node-exporter | 1 CPU / 128 MB  | Buggy collector blowing up                  |
| cAdvisor      | 1 CPU / 512 MB  | Heavy container churn                       |
| Watchtower    | 1 CPU / 256 MB  | Pull-storm during scheduled run             |

All values are tunable via `*_CPU_LIMIT` / `*_MEMORY_LIMIT` in `.env`.
Defaults are headroom-y enough that normal operation never hits them.

---

## Security defaults

- **Admin surfaces**: localhost-only by default, BasicAuth + IP
  whitelist always enforced. Public exposure is opt-in.
- **App surfaces**: minimal headers — only `X-Solution-Provider`. No
  HSTS / Permissions-Policy / Frame-Deny / rate-limits imposed by
  default. Apps choose what they need.
- **TLS**: 1.1 minimum, broad cipher list for legacy compat, no TLS 1.0.
- **Containers**: drop `ALL` capabilities, `no-new-privileges:true`,
  non-root users for Prometheus / Grafana / Loki, read-only Docker
  socket on Traefik.
- **Secrets**: `.env` is gitignored and chmod 600 by the wizard.

Future hardening (not enabled by default; PR-ready):

- Forward-auth via Authelia or Authentik for SSO across admin surfaces.
- mTLS for backend-only routers (template in `dynamic/tls.yml`).
- WAF in front (Coraza middleware plugin).
- `tecnativa/docker-socket-proxy` sidecar instead of direct socket
  mount.

---

## Backup / restore

```bash
sudo ./traefik.sh backup
# -> ${DATA_DIRECTORY}/backups/edgeproxy_YYYYMMDD_HHMMSS.tar.gz
```

Archive contains: `.env`, the entire `config/`, ACME certificate JSON,
Grafana SQLite DB, Prometheus blocks (WAL excluded), Alertmanager state.

Restore is a manual `tar -xzf` into the same `DATA_DIRECTORY` plus
`docker compose up -d`.

---

## Troubleshooting

```bash
sudo ./traefik.sh validate           # compose + traefik.yml syntax check
sudo ./traefik.sh logs traefik       # follow Traefik
sudo docker exec edgeproxy-traefik traefik version

# ACME debug
sudo cat ${DATA_DIRECTORY}/traefik/letsencrypt/letsencrypt.json | jq .
```

If Let's Encrypt rate-limits you during testing, switch the resolver to
`letsencrypt-staging` per-router via labels.

---

## License

[MIT](LICENSE) — Copyright © 2026 BAUER GROUP.

Bundled open-source components retain their own licenses. See
[`NOTICE.md`](NOTICE.md).

---

## Related stacks

- [bauer-group/CS-Coolify](https://github.com/bauer-group/CS-Coolify) —
  same management UX, Coolify self-hosting.
- [bauer-group/CI-GitHubRunner](https://github.com/bauer-group/CI-GitHubRunner) —
  same management UX, ephemeral GitHub runners.
