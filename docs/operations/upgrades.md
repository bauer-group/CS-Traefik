# Upgrades

How to update the stack — the two distinct update paths and when to
use each.

## Two paths

CS-Traefik separates **scripts/configs** from **container images**:

| Command | What it updates |
| --- | --- |
| `traefik.sh deploy` | Scripts, compose files, configs from git (origin/main) |
| `traefik.sh update` | Docker images (pulls newer tags) |

These are intentionally separate:

- A regression in scripts (`traefik.sh deploy`) leaves images
  untouched — bisect quickly.
- A regression in images (`traefik.sh update`) leaves scripts
  untouched — roll back the affected image without touching git.
- Different change cadences — scripts may rarely change; image tags
  (especially `latest`) move continuously.

## Routine upgrade flow

Weekly / monthly:

```bash
sudo /opt/edgeproxy/traefik.sh deploy   # 1. pull repo updates
sudo /opt/edgeproxy/traefik.sh update   # 2. pull newer images
```

Both are idempotent — running them when nothing's new is harmless.

### `traefik.sh deploy` step by step

1. Configure git (`core.fileMode false`, `safe.directory`).
2. Stash any local changes (you'll be reminded if anything was
   stashed).
3. Pull from `origin/main` (fast-forward; falls back to merge if
   needed).
4. Restore the stash (warns on conflict).
5. `chmod +x` the shell scripts.
6. Print the new HEAD commit.

Doesn't restart the stack — config changes apply on next `restart`
or per-file (Traefik dynamic config has `watch: true`, so YAML
changes under `config/traefik/dynamic/` apply live).

### `traefik.sh update` step by step

1. `compose pull` for every service in the active profile mix.
2. `compose up -d --remove-orphans` to recreate containers using
   the freshly-pulled images.
3. `docker image prune -f` to delete the old image layers.

This DOES restart containers — brief downtime per service. Most
services restart in under 5 seconds. Traefik itself has a 30-second
graceful-shutdown window for in-flight requests.

## Auto-update (optional)

For unattended hosts: enable the `auto-update` profile in `.env`:

```env
COMPOSE_PROFILES=monitoring,auto-update
```

Watchtower runs weekly (Sat 03:00 default), pulls newer images, and
restarts containers with rolling-restart (one at a time). See
[`profiles.md`](../profiles.md#when-to-enable-auto-update) for the
trade-offs.

Auto-update only handles **images**, not the scripts/configs from
git. You still need `traefik.sh deploy` periodically (or set up your
own cron for that).

## Pinning versus floating

Default is `latest` for monitoring images, `v3.6` for Traefik. The
`.env.example` documents how to pin:

```env
TRAEFIK_IMAGE_TAG=v3.6        # already pinned
PROMETHEUS_IMAGE_TAG=v2.55.0  # pin if compliance requires it
GRAFANA_IMAGE_TAG=11.4.0
LOKI_IMAGE_TAG=3.3.1
```

Pin in regulated / regulated-industry environments where every
container update needs change-ticket approval. Float `latest` for
self-hosted personal / small-team setups where security patches via
Watchtower are valued more than predictable release cadences.

## Major-version upgrade (Traefik v3 → v4 in the future)

When Traefik v4 ships:

1. Read the upstream migration guide.
2. **Don't** auto-update — this is exactly why we pin `TRAEFIK_IMAGE_TAG`.
3. Switch to staging cert resolver for testing:
   ```env
   LETSENCRYPT_CA=https://acme-staging-v02.api.letsencrypt.org/directory
   ```
4. Update the pin: `TRAEFIK_IMAGE_TAG=v4.0`.
5. `sudo ./traefik.sh update`.
6. Verify dashboard, then a sample app, then all apps.
7. Switch back to production CA:
   ```env
   LETSENCRYPT_CA=https://acme-v02.api.letsencrypt.org/directory
   ```
   and `sudo ./traefik.sh restart`.

If something breaks, roll back:

```env
TRAEFIK_IMAGE_TAG=v3.6
```

```bash
sudo ./traefik.sh update
```

The old `v3.6` image is still in the registry — Docker pulls it
again. ACME storage is forward + backward compatible across v3
minor versions.

## Routine OS / kernel upgrades

CS-Traefik runs in containers, isolated from the host kernel except
for:

- The Docker daemon (kernel features it depends on: cgroups, network
  namespaces, overlay2 filesystem).
- Host networking (port bindings, IPv4 / IPv6 routing).
- Host filesystems (the bind-mounted data dirs).

Routine `apt upgrade` / `dnf update` / etc. should not affect CS-
Traefik. Restart Docker if the kernel was updated:

```bash
sudo systemctl restart docker
```

Containers come back up automatically (`restart: unless-stopped` is
set on every service).

## Major upgrade gotchas

### Traefik v2.x → v3.x (which CS-Traefik already does)

Already handled by CS-Traefik. The differences from legacy v2.x are
documented in [`migration-from-v2.md`](migration-from-v2.md).

### Prometheus 2.x → 3.x (when it arrives)

- Storage format may change. Read the Prometheus migration guide
  before bumping `PROMETHEUS_IMAGE_TAG`.
- The TSDB blocks in `${DATA_DIRECTORY}/prometheus/` are typically
  forward-compatible but not always backward-compatible. Once you
  upgrade, rolling back may require throwing away historical data.

### Grafana 11.x → 12.x

Generally smooth; Grafana auto-migrates the SQLite schema on
startup. **Take a backup** of the SQLite (`${DATA_DIRECTORY}/grafana/`)
before a major version bump.

### Loki 3.x → 4.x

Schema changes may apply. Loki's compactor handles online migration
but new chunks use the new schema. Rolling back requires explicit
schema configuration. Read the upstream migration notes before
upgrading.

## Pulling specific tags

Sometimes you want to test a specific image tag without committing:

```bash
TRAEFIK_IMAGE_TAG=v3.7-beta sudo /opt/edgeproxy/traefik.sh update
```

Compose env-var override only applies for that single invocation.
Once tested, write the pin to `.env` if you want it persistent.

## Watching upgrades for regressions

After every `traefik.sh update`, watch for:

```bash
# Container health
sudo /opt/edgeproxy/traefik.sh status

# Check for ERR / WARN in logs
sudo /opt/edgeproxy/traefik.sh logs | grep -iE "err|warn|fatal" | tail -20

# Grafana → EDGEPROXY Overview dashboard
# Look for: 5xx rate spike, latency p95 spike, healthcheck-fail count
```

If something looks off, roll back the affected image tag (set the
old version in `.env`, `traefik.sh update`).

## Rollback strategy

Every Watchtower / `traefik.sh update` removes the old image. To
roll back:

1. Set the previous tag in `.env`:
   ```env
   TRAEFIK_IMAGE_TAG=v3.5    # if you upgraded to v3.6 and that broke
   ```
2. `sudo /opt/edgeproxy/traefik.sh update`.

Docker re-pulls the old version from the registry. Most images keep
old tags available — Traefik's official image keeps every minor
version forever.

For application-specific (non-CS-Traefik) services that you
auto-update, consider keeping the previous-known-good tag explicitly
pinned (`grafana:11.3.0`) so you have a known-good rollback target.
