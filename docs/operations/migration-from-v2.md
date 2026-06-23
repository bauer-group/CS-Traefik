# Migration from the legacy v2.x EDGEPROXY stack

CS-Traefik is designed as a **drop-in successor** to the legacy
EDGEPROXY v2 stack at `Z Docker Images/Traefik Reverse Proxy`. The
public network contract is byte-compatible — existing app stacks
attach without modification.

This page documents what stayed compatible, what changed, and the
migration steps.

## What stayed compatible (drop-in)

| Concern | Legacy v2.x | CS-Traefik | Status |
| --- | --- | --- | --- |
| Public network name | `EDGEPROXY` | `EDGEPROXY` | ✅ identical |
| Public bridge driver | `bridge` | `bridge` | ✅ identical |
| Entrypoints | `web` (80) + `web-secure` (443) | `web` + `web-secure` | ✅ identical (with hyphen!) |
| Cert resolver | `letsencrypt` | `letsencrypt` | ✅ identical name |
| HTTP→HTTPS redirect | per-router (apps decide) | per-router (apps decide) | ✅ identical |
| Dashboard surface | localhost:9090 + path-prefix | `127.0.0.1:9090` + path-prefix | ✅ identical pattern |
| Dashboard auth | BasicAuth + IP whitelist | BasicAuth + IP whitelist | ✅ identical |
| `respondingTimeouts` | `readTimeout=0s, writeTimeout=0s, idleTimeout=180s` | same | ✅ identical (NOT v3 default!) |
| Buffering | not applied (streaming) | not applied (streaming) | ✅ identical |

**Existing app `docker-compose.yml` files keep working without
modification.** No labels need to change.

## What's different

### Internal network name

| | Legacy | CS-Traefik |
| --- | --- | --- |
| Public | `EDGEPROXY` | `EDGEPROXY` |
| Internal | `EDGEPROXY_INTERNAL` (underscore) | `EDGEPROXY-INTERNAL` (hyphen) |

The legacy stack used underscore (`_`); Compose v2 doesn't allow `_`
in network names so we had to switch to hyphen.

**Impact**: zero, unless you have an app that explicitly attaches to
the internal network. App stacks normally only attach to the public
`EDGEPROXY` network — the internal network is for Traefik ↔
monitoring traffic.

### Traefik version

| Legacy | CS-Traefik |
| --- | --- |
| v2.11 | v3 LTS (floating major) |

Traefik v3 has a few breaking changes from v2 that **don't affect**
label-driven routing (which is what 99 % of stacks use):

- Routing rule syntax: v2's `HostRegexp(\`{host:.+}\`)` (with named
  groups) became v3's plain Go regex. **Affects only file-provider
  routes** (rare in app stacks). Docker label routes don't use named
  groups.
- v3 default `readTimeout=60s` (v2: `0s`). CS-Traefik overrides back
  to v2 behaviour explicitly — drop-in compat preserved.
- v3 changed `--metrics.prometheus.addrouterslabels` default. CS-
  Traefik enables it explicitly to keep router-labelled metrics.

### Internal port assignments

| Entrypoint | Legacy | CS-Traefik |
| --- | --- | --- |
| `web` | `80` | `80` |
| `web-secure` | `443` | `443` |
| `api` (legacy) / `monitoring` (v3) (admin UI) | `9090` | `9090` |
| `metrics` (internal) | `9080` | `8082` |
| `ping` (internal) | (n/a) | `8081` |

The metrics + ping ports are container-internal-only — no host port
mapping. Changes are invisible to app stacks. The metrics scrape
target is referenced internally in `prometheus.yml`.

### Default `bg-provider` is always-on

Legacy stack added `X-Solution-Provider: BAUER GROUP` only on the
monitoring/dashboard router. CS-Traefik wires it at the **entrypoint level**
so EVERY public response gets the header. App stacks don't need to
do anything.

### IPv4 + IPv6 dual-stack by default

Legacy stack bound only IPv4 by default (Compose `80:80` syntax).
CS-Traefik binds both IPv4 (`0.0.0.0:`) and IPv6 (`[::]:`) explicitly
for every public port.

If your DNS has only A records (no AAAA), nothing changes. If you
add AAAA records, IPv6 clients reach Traefik immediately.

### Monitoring stack is opt-in

Legacy stack always brought up Prometheus + Grafana. CS-Traefik
makes them opt-in via `COMPOSE_PROFILES=monitoring`.

If you want them, set the profile. If you have external monitoring
already, leave it off.

## Migration steps

### Approach 1: Stand up CS-Traefik on a different host (recommended)

Lowest-risk migration:

1. **Provision a new host** for CS-Traefik (or use a separate VM).
2. Install CS-Traefik via the one-line installer:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | sudo bash
   ```
3. Configure `.env` to match your existing `LETSENCRYPT_EMAIL`,
   `NETWORK_NAME` (keep `EDGEPROXY`), etc.
4. Bring CS-Traefik up: `sudo /opt/edgeproxy/traefik.sh start`.
5. Move app stacks one at a time:
   - For each app: stop on the old host, copy the compose to the
     new host, `docker compose up -d`.
   - DNS A/AAAA records still point at the old host until the app is
     fully migrated.
6. **DNS cutover** — change A/AAAA from old IP to new IP. Apps come
   online via the new Traefik immediately.
7. Decommission the old stack once the soak window passes (~1 week).

ACME storage doesn't transfer cleanly between hosts. CS-Traefik will
re-issue Let's Encrypt certs for each hostname on first request. As
long as you stay under the rate limit (300 new orders / 3 hours / 50
duplicates / week), this just works.

### Approach 2: In-place migration on the same host (faster, more risk)

If you can't easily get a new host:

1. Stop the legacy stack: `cd /path/to/legacy && docker compose down`.
2. Note the existing data: `~/.local/share/traefik/letsencrypt.json`,
   any custom config files.
3. Install CS-Traefik to a different path: `CS_TRAEFIK_INSTALL_DIR=/opt/edgeproxy curl ... | sudo bash`.
4. Configure `.env` to match.
5. **Optional**: copy the legacy ACME storage:
   ```bash
   sudo cp /path/to/legacy/data/acme.json /opt/edgeproxy/data/traefik/letsencrypt/letsencrypt.json
   sudo chmod 600 /opt/edgeproxy/data/traefik/letsencrypt/letsencrypt.json
   ```
   This avoids re-issuing certs on first start. The format is
   compatible (same Traefik ACME storage schema).
6. Start CS-Traefik: `sudo /opt/edgeproxy/traefik.sh start`.
7. App stacks join the same `EDGEPROXY` network — no app-side
   changes needed.

The brief downtime is from `legacy down` → `CS-Traefik up`. Plan a
maintenance window of ~30 seconds.

### Approach 3: Automated `install.sh upgrade` (recommended for batch rollout)

For migrating many hosts at once (the BG case: hundreds of
identically-configured `srv-containerhost*` boxes), the installer
ships a dedicated `upgrade` subcommand that automates the whole
flow with safety baked in.

```bash
# Interactive run (recommended for the first 1-2 hosts to verify):
curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh \
  | sudo bash -s -- upgrade

# Dry-run -- prints the plan without doing anything:
curl -fsSL .../install.sh | sudo bash -s -- upgrade --dry-run

# Fully automated (for batch rollout via Ansible / SSH-loops):
curl -fsSL .../install.sh | sudo bash -s -- upgrade --auto
```

What `upgrade` does, in order:

1. **Detect** the v2 stack at `/opt/edgeproxy` (the legacy default).
   Refuses to run if the path is missing or already on v3.
2. **Auto-discover running compose projects** via container labels.
   v2 stacks were often started with custom `--project-name`
   (per-host hostname pattern); the upgrade picks them up automatically
   plus a fallback list of common names.
3. **Parse the old `.env`** and pick out only the values that need to
   migrate (see table below). Everything else stays at v3 defaults.
4. **Print the plan** (skipped with `--auto`) and ask for confirmation.
5. **Stop** every detected compose project (`docker compose down
   --remove-orphans`). Volumes are PRESERVED -- nothing is deleted
   that holds historical data.
6. **Remove the legacy networks** (`EDGEPROXY`, `EDGEPROXY_INTERNAL`,
   plus name variants). Networks are recreated by the new compose.
7. **Atomic rename** `/opt/edgeproxy` -> `/opt/edgeproxy-v2-backup-<TS>`.
   Same filesystem, instant, reversible. A failure at any later step
   can be rolled back by renaming the dir back.
8. **Clone v3** to `/opt/edgeproxy`.
9. **Generate `.env`** from `.env.example` and overlay the migrated
   values:

   | Old key | Where it goes in v3 | Notes |
   | --- | --- | --- |
   | `MONITORING_USERS` | `MONITORING_USERS` | Verbatim (already bcrypt-escaped). |
   | `MONITORING_WHITELIST` | `MONITORING_WHITELIST` | Verbatim (preserves your LAN CIDRs). |
   | `GRAFANA_ADMIN_PASSWORD` | same | Verbatim. |
   | `MONITORING_PORT` | same | Migrated only if non-default (v3 default is 9090). |
   | `LETSENCRYPT_EMAIL` | same | Migrated only if non-default. |
   | `MONITORING_HOST` | split: IPs -> `MONITORING_BIND`/`MONITORING_BIND_V6`=0.0.0.0/:: | v2's HostRegexp pattern is split: IP parts trigger all-interface bind (preserves v2 0.0.0.0 behaviour AND loopback access); hostname is logged but NOT migrated to v3 `MONITORING_HOST` (v3 MONITORING_HOST is for mode-3 public-FQDN-with-LE only -- internal hostnames don't qualify). |
   | (none) | `COMPOSE_PROFILES=monitoring` | Upgrade default. |

10. **Migrate ACME certs** by calling `traefik.sh migrate-acme` on
    `<backup>/configuration/traefik/certificates/dynamic/letsencrypt.json`.
    Target resolver is `letsencrypt-tls` (preserves v2's TLS-ALPN-01
    challenge type, no rate-limit hit). Account block is preserved
    so first renewal continues under the same Let's Encrypt account.
11. **Start** the v3 stack via `traefik.sh start`.
12. **Verify** Traefik becomes healthy (poll up to 120 s).
13. **Print summary** with rollback instructions.

Recovery: at any point before the data subdirs grow beyond what the
TSDB stores in WAL, you can roll back by:

```bash
sudo /opt/edgeproxy/traefik.sh stop
sudo rm -rf /opt/edgeproxy
sudo mv /opt/edgeproxy-v2-backup-<TS> /opt/edgeproxy
sudo cd /opt/edgeproxy && docker compose --project-name <project> up -d
```

After 30 days of confirmed v3 operation (cert renewals proven
working), delete the backup:

```bash
sudo rm -rf /opt/edgeproxy-v2-backup-<TS>
```

**Batch rollout pattern** (Ansible / SSH-loop):

```bash
# bg-upgrade-all.sh -- run from a controller host
for host in $(cat hostlist.txt); do
    ssh root@"$host" \
        'curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh | bash -s -- upgrade --auto' \
        > "logs/${host}.log" 2>&1 &
    # Throttle: 5 concurrent
    [[ $(jobs -r | wc -l) -ge 5 ]] && wait -n
done
wait
```

`--auto` skips the confirmation prompt; everything else is identical
to the interactive flow. The per-host log captures the full output
for post-rollout inspection.

## Verifying drop-in compatibility for an app stack

Before doing any actual migration, verify against a sample app:

```bash
# 1. Bring CS-Traefik up alongside the legacy stack on different ports
HTTP_PORT=8081 HTTPS_PORT=8443 sudo /opt/edgeproxy/traefik.sh start

# 2. Attach an app stack to the new EDGEPROXY-test network (rename in .env)
NETWORK_NAME=EDGEPROXY-test docker compose up -d myapp

# 3. Test
curl --resolve app.bauer-group.com:8443:127.0.0.1 https://app.bauer-group.com:8443/health

# 4. If everything works, tear down test and do the real migration
```

## Things to NOT do

### Don't carry over the buffering middleware

The legacy DocumentSigning compose has:

```yaml
- "traefik.http.middlewares.${STACK_NAME}-nobuffer.buffering.maxRequestBodyBytes=0"
- "traefik.http.middlewares.${STACK_NAME}-nobuffer.buffering.memRequestBodyBytes=0"
```

This was a misconfiguration — it activates buffering with no memory
buffer (forcing all bodies to disk). Traefik's default IS streaming
without buffering. **Delete those labels** when migrating.

See [`examples/minio-s3.md`](../examples/minio-s3.md) for the
correct streaming pattern.

### Don't change the entrypoint names

Legacy uses `web` + `web-secure`. CS-Traefik uses `web` + `web-secure`
(identical). If you accidentally typed `websecure` (no hyphen) anywhere,
you'd break compat. Stick with the legacy hyphenated form.

### Don't try to migrate the legacy `EDGEPROXY_INTERNAL` network

Compose v2 doesn't allow `_` in network names. CS-Traefik uses
`EDGEPROXY-INTERNAL`. Apps don't normally attach to the internal
network anyway, so just let CS-Traefik create the new one.

### Don't disable the new dual-stack bindings

The IPv4 + IPv6 dual-stack bindings are added explicitly in
`docker-compose.yml`. If you remove the `[::]:80:80/tcp` lines, IPv6
clients lose reachability. Modern deployments need both stacks.

## Rollback plan

If something breaks during migration:

1. `sudo /opt/edgeproxy/traefik.sh stop`
2. `cd /path/to/legacy && docker compose up -d`
3. App stacks reconnect to the legacy proxy automatically (same
   network name).

Allow ~30 seconds for app discovery + cert serving. Total downtime
of a stop+start cycle should be under 1 minute.

If you migrated DNS already, change A/AAAA back to the legacy host
IP — DNS propagation takes 5-15 minutes (use a low TTL on the records
during migration window).

## Post-migration cleanup

Once CS-Traefik is stable for ~1 week:

1. Stop and remove the legacy stack: `cd /path/to/legacy && docker compose down -v`.
2. Optional: remove the legacy data directory.
3. Update internal docs / runbooks to reference CS-Traefik paths.

Don't delete the legacy ACME storage immediately — it's a backup if
something needs to be re-issued from old data.

## Common questions

**Q: Do I need to update DNS during migration?**

A: Only if you're using Approach 1 (different host). For Approach 2
(same host), DNS stays the same.

**Q: Will my apps lose certificates?**

A: New CS-Traefik issues fresh certs on first request. Brief
downtime (~30s per cert) on first hit per hostname.

If you copy the legacy `letsencrypt.json` (Approach 2 step 5), no
re-issuance happens — certs are reused.

**Q: My app needs the `${STACK_NAME}-nobuffer` middleware. Does it still work?**

A: Yes, but it's unnecessary. The middleware label still defines
the buffering middleware (Compose substitutes `${STACK_NAME}` and
defines it on Traefik). Traefik applies it. The behaviour is just
slightly worse than not applying any buffering middleware (forces
disk-spill). Migrate to NO buffering middleware when you can — your
S3/upload paths get faster.

**Q: My app uses `tls.certresolver=letsencrypt-tlschallenge`. Does that work?**

A: No — that resolver name doesn't exist in CS-Traefik. The legacy
stack might have used a custom name. CS-Traefik's resolvers are
`letsencrypt` (HTTP-01), `letsencrypt-tls` (TLS-ALPN-01),
`letsencrypt-dns` (DNS-01), `letsencrypt-staging` (HTTP-01 staging).

Update your label to `letsencrypt-tls` if you specifically need
TLS-ALPN-01, otherwise plain `letsencrypt` works.
