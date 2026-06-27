# Known Limitations & Untested Areas

This page is the honest counterpart to the rest of the documentation:
**what the stack does NOT cover well, what is intentional but
imperfect, and what was deliberately not exercised in the local
validation pass.** None of these are blocking issues for typical
edge-proxy operation; they are the corners that need explicit
operator awareness.

## Loki cold-start window (~15 s)

Loki ships from `gcr.io/distroless/static-debian12:nonroot` -- no
shell, no wget, no curl. Compose has no native TCP healthcheck, so
the `loki` service in `docker-compose.monitoring.yml` carries **no
healthcheck**, and Grafana / Promtail depend on it via
`condition: service_started` (not `service_healthy`).

Practical consequence on a cold start:

```text
t = 0 s    Loki container started. Binary alive.
t = 0..15  Loki logs "waiting 15s after being ready before starting
           compactor". HTTP /ready returns 503 ("Ingester not ready").
           Promtail pushes succeed (write path is ready earlier).
           Grafana queries return 503; dashboards show "no data".
t = 15+    HTTP /ready returns 200. Steady state.
```

Promtail and Grafana both retry, so steady-state operation is fine.
Only first-load Grafana dashboards may flash empty briefly. If your
environment cannot tolerate the window:

- **Custom Loki image** with shell + wget added. Maintenance burden:
  rebuild on every Loki release.
- **Sidecar HTTP probe** that exits 0 when Loki `/ready` returns
  200, then `depends_on:` with
  `condition: service_completed_successfully`. Adds one container.
- **External `blackbox_exporter`** probing `/ready`, with Grafana
  loading dashboards conditionally on alert state. Heavyweight.

The trade-off was accepted because the failure mode (15 s of empty
dashboards on cold start) is not user-visible in production where
the stack runs continuously.

## Grafana → Alertmanager `/health` returns `plugin.unavailable`

Grafana's Alertmanager-datasource health-check endpoint
(`/api/datasources/uid/alertmanager/health`) returns HTTP 500 with
message `plugin.unavailable`, even though queries through the same
datasource (`/api/datasources/proxy/uid/alertmanager/api/v2/status`)
work correctly and return live data.

This is a Grafana-side plugin quirk -- the Alertmanager datasource
plugin does not implement the health-check API the same way the
Prometheus / Loki plugins do. Verified separately: the alertmanager
URL with the `/alertmanager` route prefix appended is correct, the
service is reachable, and dashboard panels that query alertmanager
render fine.

If your deployment workflow gates on Grafana health checks, this is
the one false positive to filter out. The datasource itself is
functional.

## Docker Desktop on Windows / WSL2 quirks

Two test-environment-specific issues that DO NOT manifest on Linux
native Docker:

### `rslave` mount-propagation

`node-exporter` originally mounted `/:/host/root:ro,rslave` -- the
`rslave` flag requires `/` on the host to be a shared or slave
mount, which it is on Linux but NOT on WSL2. The fix
(`/:/host/root:ro` plain) is cross-platform; the trade-off is that
node-exporter will not auto-detect filesystems mounted on the host
**after** its start (a restart picks them up). Acceptable for typical
edge-proxy hosts where new disks/mounts are rare events.

### Source-IP munging through Docker port-forward

When the host loopback `127.0.0.1:<HOST_PORT>` is forwarded to a
container port, Docker rewrites the source IP to the gateway of the
first network attached to the container (`100.65.0.1` for our `proxy`
network). Traefik therefore sees `100.65.0.1`, never `127.0.0.1`.

This is **NOT** Docker-Desktop/Windows-specific (an earlier version of
this note claimed Linux native preserves `127.0.0.1` -- that is wrong).
Loopback-published ports always route through the `docker-proxy`
userland helper, because the kernel cannot DNAT loopback-destined
packets straight into the bridge. `docker-proxy` opens a fresh
connection to the container from the bridge gateway, so the masquerade
happens on Linux native Docker too -- independent of the daemon's
`userland-proxy` flag. Verified on a production Linux host: an SSH
tunnel to `127.0.0.1:9090` lands at Traefik as `ClientHost: 100.65.0.1`.

Effect on this stack: a request to the admin entrypoint via
`curl 127.0.0.1:9090/dashboard/` (locally or through an SSH tunnel)
arrives as `100.65.0.1`. The IP whitelist must therefore include
`100.65.0.1/32` for the tunnel path to clear the gate (BasicAuth still
applies on top).

Resolution: the shipped default `MONITORING_WHITELIST` now includes
`100.65.0.1/32` precisely so SSH-tunnel access works out of the box.
No `.env` edit is needed for the standard tunnel workflow. (If you ever
see a `403` on the tunnel and the gateway entry is missing, re-add it --
do NOT broaden to `100.65.0.0/16`, which would expose the admin gate to
the whole public app network.)

## Areas not exercised in the local validation pass

The bring-up + integration tests verified that every service
**runs** and **connects to the others**. The tests deliberately did
not exercise:

| Area | Reason for skipping | How to verify before production |
| --- | --- | --- |
| Real Let's Encrypt ACME issuance | Test environment has no public DNS / no real hostname. Default `LETSENCRYPT_CA` was switched to staging during tests. | Deploy to a staging server with a real hostname; switch `LETSENCRYPT_CA` to production; verify cert appears in `/etc/traefik/certs/letsencrypt/letsencrypt.json` and TLS handshake serves it. |
| HTTP/3 (QUIC over UDP/443) | The entrypoint is configured but Docker Desktop's UDP forwarding has different behaviour from Linux. Browser-level QUIC negotiation needs a real client. | `curl --http3-only https://your-host/...` (curl built with HTTP/3 support) or browser DevTools showing `h3` protocol. |
| IPv6 routing path end-to-end | Docker Desktop's IPv6 forwarding is functional but quirky; full v6 testing belongs on a dual-stack Linux host. | `curl -6 https://your-host/...` from an IPv6-capable network; verify access logs show v6 source. |
| Alert firing through Alertmanager | Rules are loaded (12 rules across 3 groups) but no rule was forced into a firing state during tests. | Trigger a known-firing condition (e.g. stop a target Prometheus is scraping; the `TraefikDown` alert fires within 1-2 evaluation cycles). Verify Alertmanager `/api/v2/alerts` shows the alert. |
| Grafana dashboard panels rendering with data | Datasources connected, but no panel was opened in a browser to verify visualisation. | SSH-tunnel to `127.0.0.1:9090/grafana/`, log in, open each provisioned dashboard ("EDGEPROXY -- Containers", "-- Logs Explorer", "-- Overview"). |
| Cgroup resource-limit enforcement | `deploy.resources.limits` declarations were checked in the compose config; Cgroup-level enforcement under stress was not. | Use `docker stats` while running a load generator; verify CPU caps are honoured (the throttled-time counter increases). |
| Failover behaviour | Services were not killed mid-operation. | Stop Loki (`docker compose stop loki`); verify Promtail buffers / retries without crashing, Grafana shows clear error on log queries; restart Loki and verify recovery. |
| Long-term stability | Tests ran for minutes, not days. Memory leaks, log-rotation under sustained ingest, ACME renewal cycle (60-day pre-expiry trigger) all need real-time observation. | Run a staging deployment for at least one ACME renewal cycle (60 days) before promoting. |

## Resource isolation: what the stack does (and does NOT) touch on the host

The stack is layered to ensure that no monitoring container can ever
take down Traefik, but ALSO that no setting reaches into the host's
own kernel / systemd / Docker-engine state.

### What is configured (per-container only)

All settings below are container-scoped via Docker / cgroup
mechanisms. None of them modify the host kernel, sysctl, /etc, or
systemd:

**OOM hierarchy (under host memory pressure):**

| Tier | Process / Container | `oom_score_adj` | Notes |
| --- | --- | --- | --- |
| 0 | systemd init / kernel threads | n/a (immune) | Kernel auto-protects. |
| 1 | sshd, dockerd | -500 (distro default) | Verify with `traefik.sh check-host-isolation`. |
| 2 | **traefik** | **-50** | Light bias only. A reverse proxy without backends is dead weight, so Traefik does not get tier-strong protection -- it shares the danger zone with apps. |
| 3 | customer-facing apps | 0 (no override) | Killed before monitoring, in roughly the same band as Traefik. |
| 4 | monitoring helpers | +200 | Preferred OOM victim (intentional). |

**Per-container cgroup settings** (small-host defaults; overridable via `.env`):

| Container | `oom_score_adj` | Default Memory | Default CPU |
| --- | --- | --- | --- |
| traefik | -50 | (uncapped on purpose) | (uncapped on purpose) |
| prometheus | +200 | `${PROMETHEUS_MEMORY_LIMIT:-1g}` | `${PROMETHEUS_CPU_LIMIT:-1}` |
| grafana | +200 | `${GRAFANA_MEMORY_LIMIT:-1g}` | `${GRAFANA_CPU_LIMIT:-1}` |
| loki | +200 | `${LOKI_MEMORY_LIMIT:-768m}` | `${LOKI_CPU_LIMIT:-1}` |
| promtail | +200 | `${PROMTAIL_MEMORY_LIMIT:-256m}` | `${PROMTAIL_CPU_LIMIT:-0.5}` |
| alertmanager | +200 | `${ALERTMANAGER_MEMORY_LIMIT:-128m}` | `${ALERTMANAGER_CPU_LIMIT:-0.25}` |
| node-exporter | +200 | `${NODE_EXPORTER_MEMORY_LIMIT:-128m}` | `${NODE_EXPORTER_CPU_LIMIT:-0.25}` |
| cadvisor | +200 | `${CADVISOR_MEMORY_LIMIT:-384m}` | `${CADVISOR_CPU_LIMIT:-0.5}` |
| watchtower | +200 | `${WATCHTOWER_MEMORY_LIMIT:-256m}` | `${WATCHTOWER_CPU_LIMIT:-0.5}` |

**No `pids_limit`** is set on any container by design. Per-container
PID caps look harmless but in practice are a footgun: legitimate
service workloads (Prometheus on a busy host, Grafana with several
plugins, cAdvisor in high-churn environments) routinely vary in
thread count and a sensible cap is hard to set without occasionally
strangling normal operation. Without `pids_limit`, containers
inherit the host PID quota (typically 4 million), which is plenty.

Defaults sized for an 8 GB / 4-core host (small-host-safe). Total
monitoring footprint: ~3.2 GB memory caps, ~5 cores total cap.
Larger hosts override the values via `.env` -- see commented
examples in `.env.example`.

### What the stack does NOT touch on the host

- No modifications to `/etc/sysctl.conf` or any `/proc/sys/...` writes.
- No installed systemd units, no `OOMScoreAdjust=` set on
  `dockerd.service` or any host service.
- No host-wide ulimit / PAM changes.
- No persistent kernel parameters (`/etc/sysctl.d/...`).
- The only host filesystem the stack writes to is `${DATA_DIRECTORY}`
  (default `./data` -- relative to the install dir, gitignored, so
  resolves to `/opt/edgeproxy/data/` after a default install).
- Read-only mounts (`/proc`, `/sys`, `/var/lib/docker`,
  `/var/run/docker.sock`) are observation surfaces for node-exporter,
  cAdvisor and Promtail. The mode is `:ro` -- writes from the
  container would fail at the kernel boundary even if the container
  process tried.

### What the stack EXPECTS the host to provide

This stack does not modify host services, so a few host-level
settings are the operator's responsibility for full memory-pressure
robustness. **All optional -- the stack runs without them, just with
slightly lower guarantees in extreme OOM scenarios:**

- **`dockerd.service` should have `OOMScoreAdjust=-500`** (or stronger
  negative) at the systemd unit level. Most modern distros set this
  in their packaging by default. Verify with:

  ```bash
  systemctl show dockerd | grep -i OOMScoreAdjust
  # Expected: OOMScoreAdjust=-500 (or similar negative)
  ```

  If unset on your distro, add a drop-in (does not touch our stack):

  ```bash
  sudo systemctl edit dockerd
  # add the two lines:
  [Service]
  OOMScoreAdjust=-500
  ```

- **`sshd` should be similarly protected** so an OOM event under load
  cannot lock you out of the host.

- **Disk for `${DATA_DIRECTORY}`** ideally on a separate volume so
  Prometheus TSDB / Loki chunk writes do not contend with the
  Traefik log file or the OS root partition.

If your environment runs without backend services that can take the
hit and you want Traefik more aggressively protected, override
`oom_score_adj` to a stronger negative in
`docker-compose.override.yml`:

```yaml
services:
  traefik:
    oom_score_adj: -200   # stronger than the shipped -50
    # or -500 to match a typical distro-protected dockerd, but
    # be aware: dockerd / sshd should still be MORE protected
    # than Traefik for host recoverability.
```

The shipped default of `-50` is intentionally light because a reverse
proxy without backends is dead weight: if apps are dying to free
memory, killing Traefik first is often the right outcome (faster
fail-fast for the load balancer in front). Raise the protection only
if your apps are inelastic to brief memory pressure.

## Healthcheck `start_period` reference

Tuned values in the shipped compose files:

| Service | start_period | Tuning rationale |
| --- | --- | --- |
| traefik | 10 s | Traefik starts in 1-3 s; 10 s is comfortable headroom. |
| prometheus | 60 s | WAL replay on a multi-GB TSDB takes 30-90 s. 60 s covers typical 30-day retention. |
| grafana | 60 s | `GF_INSTALL_PLUGINS` triggers per-plugin download + extract on cold start (5-15 s each). 60 s tolerates a couple plugins. |
| alertmanager | 30 s | Lightweight; 30 s suffices unless running multi-replica HA gossip. |
| loki | none | See "Loki cold-start window" above. |
| promtail / node-exporter / cadvisor / watchtower | none / image-builtin | Either no HTTP endpoint to probe or the upstream image's `HEALTHCHECK` is sufficient. |

If your environment has materially different startup characteristics
(slower disk, larger TSDB, many Grafana plugins), bump `start_period`
in `docker-compose.override.yml`.
