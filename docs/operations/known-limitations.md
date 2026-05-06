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
container port, Docker Desktop on Windows rewrites the source IP to
the gateway of the first network attached to the container (e.g.
`100.65.0.1` for our public network). Linux native Docker preserves
`127.0.0.1`.

Effect on this stack: testing the admin entrypoint via
`curl 127.0.0.1:9090/dashboard/` from the Docker Desktop host
returns 403 (IP whitelist rejects 100.65.0.1) even with valid
BasicAuth credentials. SSH-tunnelling to a real Linux deployment
works correctly because the source IP IS 127.0.0.1 there.

Workaround for local development: temporarily add `100.65.0.0/16` to
`API_WHITELIST` in your local `.env`. Do NOT commit this change --
it is platform-specific debug aid, not a production policy.

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
