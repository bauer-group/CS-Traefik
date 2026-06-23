# Compose Profiles

CS-Traefik uses Compose's native `profiles:` mechanism to make
optional features opt-in. The default install brings up Traefik
alone — monitoring and auto-update are activated by setting
`COMPOSE_PROFILES` in `.env`.

## Available profiles

| Profile | Activates | Adds to host |
| --- | --- | --- |
| *(none)* — `core` | Just Traefik | `traefik` container |
| `monitoring` | Prometheus + Grafana + Loki + Promtail + Alertmanager + node-exporter + cAdvisor | 7 containers, ~3.2 GB RAM cap (small-host defaults) |
| `auto-update` | Watchtower | 1 container, weekly cron (Sat 03:00 default) |

Combine with comma:

```env
# core only (default)
COMPOSE_PROFILES=

# core + observability
COMPOSE_PROFILES=monitoring

# core + auto-update (no monitoring)
COMPOSE_PROFILES=auto-update

# everything
COMPOSE_PROFILES=monitoring,auto-update
```

Apply changes with:

```bash
sudo ./traefik.sh restart
```

`traefik.sh` reads `COMPOSE_PROFILES` from `.env` and constructs the
right `docker compose -f file1.yml -f file2.yml --profile X` invocation
internally — you don't need to remember the multi-file flags.

## Architecture: profiles + overlays

Two distinct mechanisms work together:

1. **Compose overlays** — separate `docker-compose.*.yml` files. Each
   profile has its own file:
   - [`docker-compose.yml`](../docker-compose.yml) — core (always loaded)
   - [`docker-compose.monitoring.yml`](../docker-compose.monitoring.yml)
     — monitoring profile services
   - [`docker-compose.auto-update.yml`](../docker-compose.auto-update.yml)
     — auto-update profile service

2. **Compose profiles** — every service in the overlays has
   `profiles: [monitoring]` or `profiles: [auto-update]`. This means
   the service is **only started** when the matching profile is active.

`traefik.sh` reads `COMPOSE_PROFILES` from `.env` and:

1. Loads `docker-compose.yml` always.
2. Loads each overlay file matching an active profile.
3. Passes `--profile X` for each active profile so services with
   `profiles:` keys actually start.

This hybrid approach has two benefits:

- **Disk usage** — when a profile is off, its overlay isn't loaded,
  so its volumes/networks aren't created (no orphaned `prometheus-data`
  volume on a core-only install).
- **Start-up speed** — Compose only schedules services that are
  selected, no overhead for inactive profiles.

## Why core-only is the default

The wizard defaults `monitoring=N`, `auto-update=N`. New deployments
get just Traefik. Users opt in to extras.

Reasoning:

- **Monitoring stack is non-trivial** — 7 containers, ~3.2 GB RAM cap
  with small-host defaults (fits on an 8 GB / 4-core host). Many
  deployments don't need it; they use external monitoring (Datadog,
  New Relic, Grafana Cloud, ...). Bump per-service caps via `.env` if
  you ingest >50 GB/day logs or run >20 scrape targets.
- **Auto-update is a policy decision** — some operators want manual
  control over when their proxy restarts. Watchtower's rolling-restart
  is safe but introduces uncontrolled timing.

## When to enable `monitoring`

Enable when:

- This is your primary monitoring solution (no external observability).
- You want the pre-built Traefik / containers / logs dashboards.
- You want alert rules running for host CPU / disk / cert expiry /
  container OOM.

Skip when:

- You already pay for Datadog / New Relic / etc. — adding Prometheus
  duplicates the metrics.
- The host is severely RAM-constrained (<6 GB total free for the stack).
- This is a dev/local environment.

## When to enable `auto-update`

Enable when:

- The host is unattended (no operator checks weekly).
- You want CVE-driven base-image updates without manual intervention.
- Your apps are tolerant of unscheduled restarts (rolling, but
  uncontrolled timing).

Skip when:

- You're in a regulated environment that requires change tickets for
  every container restart.
- You have apps that need scheduled coordination across the fleet
  (e.g. database master/replica failover that must happen in a
  specific window).
- You prefer manual `./traefik.sh update` runs.

## Auto-update details

Watchtower runs weekly (Saturday 03:00 by default) and:

1. Polls all configured registries for newer images of containers
   labeled `com.centurylinklabs.watchtower.enable=true`.
2. Pulls newer images.
3. Stops + recreates containers using rolling restart (one at a time
   so the stack stays up).
4. Prunes the old image.

**Labelled services** (every CS-Traefik service is labelled):

- `traefik`
- `prometheus`
- `grafana`
- `loki`
- `promtail`
- `alertmanager`
- `node-exporter`
- `cadvisor`
- `watchtower` (self-update)

Customise the schedule via `WATCHTOWER_SCHEDULE` (six-field cron):

```env
WATCHTOWER_SCHEDULE=0 0 3 * * 6   # Sat 03:00 (default)
WATCHTOWER_SCHEDULE=0 0 4 * * 0   # Sun 04:00
WATCHTOWER_SCHEDULE=0 0 */6 * * * # every 6 hours (aggressive)
```

**Pinning an exact minor stops auto-update for that image**. The
default `TRAEFIK_IMAGE_TAG=v3` is a floating major tag: when v3.7
ships, `traefik:v3` resolves to a new digest and Watchtower rolls it
in. Pin an exact minor (`TRAEFIK_IMAGE_TAG=v3.6`) and Watchtower sees
the same digest on `traefik:v3.6` → no update. So: float `v3` to ride
minor/patch automatically, pin `v3.6` to freeze. A `v4` jump never
happens on the `v3` tag -- that's always a deliberate `.env` change.

**Notifications**: set `WATCHTOWER_NOTIFICATIONS=slack` (or `email`,
`telegram`, etc.) in `.env`. See `.env.example` for the full template.

## Inspecting the active profile mix

```bash
sudo ./traefik.sh status
```

Output ends with:

```
--> Active profiles:
  monitoring,auto-update
```

Or for more detail:

```bash
docker compose -f docker-compose.yml \
               -f docker-compose.monitoring.yml \
               -f docker-compose.auto-update.yml \
               --profile monitoring --profile auto-update \
               ps
```

Lists running containers per profile.
