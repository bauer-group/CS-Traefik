# Monitoring

What the `monitoring` profile activates, what each component does,
and how the data flows.

## Overview

Activate via `.env`:

```env
COMPOSE_PROFILES=monitoring
```

Then `sudo ./traefik.sh restart`. Seven services come up alongside
Traefik:

| Service | Role | Reachable | Data |
| --- | --- | --- | --- |
| **Prometheus** | Metrics TSDB + scraper | api/`/prometheus` | `${DATA_DIRECTORY}/prometheus/` |
| **Grafana** | Visualisation UI | api/`/grafana` | `${DATA_DIRECTORY}/grafana/` |
| **Loki** | Log aggregator | internal-only | `${DATA_DIRECTORY}/loki/` |
| **Promtail** | Log shipper | internal-only | `${DATA_DIRECTORY}/promtail/` |
| **Alertmanager** | Alert routing | api/`/alertmanager` | `${DATA_DIRECTORY}/alertmanager/` |
| **node-exporter** | Host metrics | internal-only | (none -- reads `/proc`, `/sys`) |
| **cAdvisor** | Container metrics | internal-only | (none -- reads cgroups) |

All admin UIs sit behind the `api` entrypoint with BasicAuth + IP
whitelist (see [`admin-access.md`](admin-access.md)).

## Data flows

```text
                         /metrics + access.log + traefik.log
                              │
            ┌─────────────────┼─────────────────┐
            ▼                 ▼                 ▼
      ┌──────────┐      ┌──────────┐
      │ Promtail │      │Prometheus│ ◄── node-exporter
      │ (reads   │      │ (scrapes │ ◄── cAdvisor
      │  Docker  │      │  /metrics│ ◄── traefik (8082)
      │  logs)   │      │  every   │ ◄── grafana / loki / alertmanager
      └─────┬────┘      │  15s)    │
            ▼           └────┬─┬───┘
      ┌──────────┐           │ │
      │   Loki   │           │ └──► Alertmanager ──► Slack/Email
      │ (stores) │           │      (rules: alerts.yml)
      └─────┬────┘           ▼
            └──────► Grafana ◄──────  Browser
                      (UI on /grafana,
                       BasicAuth + IP whitelist)
```

Two parallel pipelines:

- **Metrics**: scrape pull from sources → Prometheus TSDB → Grafana
  query / Alertmanager rules.
- **Logs**: Docker json-file driver writes container stdout → Promtail
  reads + parses → Loki stores → Grafana query.

The two pipelines are independent. If Loki is down, metrics keep
working. If Prometheus is down, logs keep working.

## Prometheus

**What it does**: pulls `/metrics` from configured targets every 15s
and stores time-series data in its embedded TSDB.

**Targets** (defined in
[`config/prometheus/prometheus.yml`](../config/prometheus/prometheus.yml)):

- `prometheus` (self)
- `traefik:8082` — Traefik's internal metrics entrypoint
- `node-exporter:9100` — host CPU/memory/disk/network
- `cadvisor:8080` — per-container CPU/memory/IO
- `loki:3100` — Loki self-metrics
- `grafana:3000/metrics` — Grafana self-metrics
- `alertmanager:9093` — Alertmanager self-metrics

**Retention** (configurable in `.env`):

```env
PROMETHEUS_RETENTION_TIME=30d   # 30 days
PROMETHEUS_RETENTION_SIZE=8GB   # whichever hits first wins
```

**Web UI**: `http://127.0.0.1:9090/prometheus/` (or
`https://${API_HOST}/prometheus/` in mode 3). Useful for ad-hoc PromQL
queries during debugging — Grafana is the long-form query interface.

**Resource cap**: 1 CPU / 1 GB RAM by default — small-host-safe (8 GB /
4-core host). Sized for ~6-10 scrape targets at 15s intervals. Bump to
2 CPU / 2 GB on hosts with 16+ GB RAM and >20 scrape targets. Cap
protects against cardinality-explosion (label-leak in apps creating
millions of series).

## Grafana

**What it does**: visualisation. Pulls from Prometheus + Loki
datasources, renders dashboards.

**Pre-provisioned dashboards** (11 dashboards / 87 panels in
[`config/grafana/dashboards/`](../config/grafana/dashboards/)):

| Dashboard | UID | What it shows |
| --- | --- | --- |
| EDGEPROXY — Home | `edgeproxy-home` | Landing page with auto-listed dashboard index + 6 live KPI stats with drill-down links. Set as Grafana's default dashboard for "open Grafana, see everything important". |
| EDGEPROXY — Overview | `edgeproxy-overview` | KPIs (Traefik up, req/s, 5xx ratio, p95 latency, firing alerts), per-service latency timeseries with SLO threshold lines, host CPU/mem/disk gauges, recent 5xx access logs. |
| EDGEPROXY — HTTP Traffic | `edgeproxy-http-traffic` | Top routers/services, latency heatmap (full distribution, slow-tail visible), bandwidth, method mix, status-code stack. Filter via `$service` / `$router` variables. |
| EDGEPROXY — Backends | `edgeproxy-backends` | Per-service open connections, retry rate, latency-quantile matrix (p50/p95/p99 in one table), recent backend errors. Filter via `$service`. |
| EDGEPROXY — TLS & Certificates | `edgeproxy-tls` | Cert inventory sorted by expiry, days-to-expiry timeline plot, ACME activity log via Loki. |
| EDGEPROXY — Alerts | `edgeproxy-alerts` | Currently firing alerts, alert history, rule-eval health, notification pipeline, alertmanager silences. |
| EDGEPROXY — SLI / SLO | `edgeproxy-slo` | 28-day availability gauge, p95 latency, error-budget burn (multi-window 1h/6h/24h per Google SRE workbook), per-service SLO table. Targets configurable via dashboard variables. |
| EDGEPROXY — Client Analysis | `edgeproxy-clients` | Top source IPs, abuse signals (401/403 by client over time), probe / scan signature log (regex over `.env`, `.git`, `wp-admin`, etc.). |
| EDGEPROXY — Containers | `edgeproxy-containers` | Per-container CPU/mem/network/throttle, restart count, OOM events. |
| EDGEPROXY — Self-Monitoring | `edgeproxy-self-monitoring` | Prometheus TSDB cardinality / WAL-replay / scrape-pool, Loki ingest + active streams. The "monitoring of monitoring" view. |
| EDGEPROXY — Logs Explorer | `edgeproxy-logs` | Loki-backed log search across the stack with `$stack` / `$container` / `$search` filters. |

Cross-dashboard navigation: Overview's KPI stats carry data-links so
clicking the Request-Rate stat opens HTTP Traffic, the 5xx-Ratio stat
opens Backends, the p95 stat opens SLI/SLO, the Firing-Alerts stat
opens Alerts. Time-series panels carry annotation queries that
overlay vertical red lines when an alert was firing -- visual
correlation of metric anomalies with alert events.

Want the standard community dashboards too? Import via Grafana UI:

| Dashboard | Grafana.com ID |
| --- | --- |
| Node Exporter Full | 1860 |
| cAdvisor / Docker | 14282 |
| Traefik 3 Official | 17347 |
| Loki Logs / App | 13639 |

**Pre-provisioned datasources** (in
[`config/grafana/provisioning/datasources/`](../config/grafana/provisioning/datasources/)):

- Prometheus (UID: `prometheus`) — `http://prometheus:9090/prometheus`
  (sub-path because Prometheus runs with `--web.route-prefix=/prometheus`).
- Loki (UID: `loki`) — `http://loki:3100`
  (no route-prefix, served at root).
- Alertmanager (UID: `alertmanager`) — `http://alertmanager:9093/alertmanager`
  (sub-path because Alertmanager runs with `--web.route-prefix=/alertmanager`).

**Grafana login**: disabled by default — the api-entrypoint BasicAuth
(`api-auth@docker` + `api-whitelist@docker`, same chain as Prometheus
and Alertmanager) is the single auth wall. Anonymous role is `Admin`,
so anyone past the edge gets full edit rights without a second login.
`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` in `.env` still seed
the DB admin for HTTP-API use and `grafana-cli admin reset-admin-
password` recovery. To swap in OAuth / OIDC later, flip
`GF_AUTH_DISABLE_LOGIN_FORM=false` + configure the SSO provider via
`GF_AUTH_GENERIC_OAUTH_*` (compose overlay).

**Sub-path serving**: Grafana is served at `/grafana` via
`GF_SERVER_ROOT_URL` + `GF_SERVER_SERVE_FROM_SUB_PATH=true`. All
internal redirects work correctly — no need to special-case URL
generation.

**Resource cap**: 1 CPU / 384 MB RAM by default — small-host-safe.
Grafana is mostly idle; the limit only matters when many concurrent
users render heavy dashboards. Bump on multi-user installs.

## Loki

**What it does**: log aggregator. Stores indexed logs (label-based,
not full-text). Query via LogQL through Grafana.

**Mode**: single-binary "filesystem" — ingester, distributor, querier,
and compactor in one process, with chunks on local disk. Right size
for a single-host edge proxy. Scale to read/write microservices when
you outgrow this (>1 TB/day ingest).

**Schema** (TSDB v13 — Loki's modern indexed-storage format):

- Chunks: `${DATA_DIRECTORY}/loki/chunks/`
- Index: `${DATA_DIRECTORY}/loki/index/`
- WAL: `${DATA_DIRECTORY}/loki/wal/`

**Retention** (configurable):

```env
LOKI_RETENTION_PERIOD=168h   # 7 days
```

Bumped via `limits_config.retention_period` in
[`config/loki/loki-config.yml`](../config/loki/loki-config.yml).
Compactor handles deletion automatically.

**Ingestion limits**:

- 8 MB/s sustained, 16 MB burst.
- 5000 streams per user (max unique label combinations).
- Hard caps that protect against runaway label-cardinality.

**Not exposed** to the host. Only Promtail (writer) and Grafana
(reader) talk to Loki, and they all live on `EDGEPROXY-INTERNAL`.

**Resource cap**: 1 CPU / 768 MB RAM by default — small-host-safe.
Loki spends most CPU on chunk compression and most RAM on the index
cache. If you ingest >50 GB/day, bump to 2 CPU / 2 GB.

## Promtail

**What it does**: log shipper. Reads container logs and forwards them
to Loki with parsed labels.

**Sources**:

- **Docker container logs**: discovers every container via the Docker
  API (read-only socket), tails their json-file driver logs, ships to
  Loki. Labels include `container`, `service`, `project`, `stream`,
  `level`.
- **Traefik file logs**: reads `${DATA_DIRECTORY}/traefik/logs/access.log`
  and `traefik.log` directly, parses the JSON format, ships to Loki
  with labels `status`, `method`, `host`, `router`.

The dual ingestion is intentional:

- Container stdout logs are easy but lossy when truncated/rotated.
- Traefik's file logs are the authoritative access log, parsed for
  request/response details.

Both are queryable in Grafana Logs Explorer. Filter by source:

```logql
{job="traefik", source="access", status=~"5.."}
{stack="edgeproxy", container="traefik"}
```

**Position file**: `${DATA_DIRECTORY}/promtail/positions.yaml` —
Promtail resumes reading from where it left off after a restart.

**Resource cap**: 0.5 CPU / 256 MB RAM. Lightweight by design — Promtail
is mostly I/O wait. CPU only spikes during initial backfill of long
log files after a restart.

## Alertmanager

**What it does**: receives alert events from Prometheus, routes to
notification channels.

**Pre-configured alert rules** (in
[`config/prometheus/alerts.yml`](../config/prometheus/alerts.yml)):

| Group | Alerts |
| --- | --- |
| `host` | HostHighCpuLoad, HostMemoryUsageHigh, HostDiskSpaceLow, HostDiskSpaceCritical, HostUnreachable |
| `containers` | ContainerKilled, ContainerCpuThrottled, ContainerMemoryNearLimit |
| `traefik` | TraefikDown, TraefikHighHttp5xxRate, TraefikHighHttp4xxRate, TraefikCertExpiringSoon |

**Notification channels**: default config prints alerts to the
container log only. Plug in receivers via
[`config/alertmanager/alertmanager.yml`](../config/alertmanager/alertmanager.yml):

```yaml
receivers:
  - name: default
    slack_configs:
      - api_url: "https://hooks.slack.com/services/T0xxxxxx/B0xxxxxx/xxxxxxxxxxxxxxxxxxxxxxxx"
        channel: "#alerts"
        send_resolved: true
        title: "[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}"
        text: |
          {{ range .Alerts -}}
          *Severity:* {{ .Labels.severity }}
          *Instance:* {{ .Labels.instance }}
          *Summary:*  {{ .Annotations.summary }}
          *Details:*  {{ .Annotations.description }}
          {{ end }}
```

Slack / email / Telegram / PagerDuty / Opsgenie / generic-webhook
receivers all work — see the
[Alertmanager docs](https://prometheus.io/docs/alerting/latest/configuration/).

**Inhibition rules**: critical alerts suppress matching warning-level
alerts for the same target (so one HostDiskSpaceCritical doesn't ALSO
fire HostDiskSpaceLow as a separate page).

**Resource cap**: 0.25 CPU / 128 MB RAM. Alertmanager is event-driven
and idle most of the time; minimal footprint is sufficient.

## node-exporter

**What it does**: exports host-level metrics for Prometheus.

**Runs with `pid: host`**: needs to read host-level `/proc` and `/sys`
to get accurate metrics. Without `pid: host`, it would only see the
container's own pid namespace.

**Bind mounts**:

- `/proc` (read-only) — process / CPU / memory metrics
- `/sys` (read-only) — disk / network metrics
- `/` (read-only, rslave propagation) — filesystem metrics

**Capabilities**: drops `ALL`, re-adds `SYS_TIME` (for clock-skew
metric).

**Filesystem exclusions**: skips Docker-internal mount points (overlayfs,
container rootfs) so the metrics show host disk usage, not container
disk usage. The latter comes from cAdvisor.

## cAdvisor

**What it does**: per-container metrics — CPU, memory working set,
network IO, block IO, CPU throttle percentage.

**Privileged**: needed for cgroup access. The container reads
`/sys/fs/cgroup` to track every container running on the host.

**Disabled metrics**: `accelerator,cpu_topology,disk,memory_numa,
tcp,udp,percpu,sched,process,hugetlb,referenced_memory,resctrl,
cpuset,advtcp,memory_numa,oom_event` — these are exotic and produce
high-cardinality time series that bloat the TSDB without operational
value.

**Why the CPU-throttle metric matters**: when a container hits its
CPU limit, the kernel CFS scheduler throttles it. Throttling shows up
as latency spikes from the inside but not as 100 % CPU usage from the
outside. The `container_cpu_cfs_throttled_periods_total` metric is the
ground truth — if it's increasing for a service, that service is
under-provisioned.

The pre-configured `ContainerCpuThrottled` alert fires when >25 % of
CPU periods are throttled.

## What "non-blocking logging" guarantees

All services use the Docker `json-file` driver in `mode: non-blocking`
with a 4 MB ring buffer per container.

If Loki / Promtail / log shipper stalls — even for several minutes —
the application's `write()` to stdout returns immediately. The driver
drops log lines once the buffer is full, but the application keeps
serving requests.

This breaks the textbook log-pipeline cascade:

```text
Loki slow / down ──► Promtail buffers fill ──► Promtail stops reading
                  ──► Docker json-file buffer fills
                  ──► WITHOUT non-blocking: stdout write() blocks
                      ──► Traefik request handler blocks on access-log
                      ──► 502s, timeouts
                  ──► WITH non-blocking (the default here):
                      log lines dropped, Traefik continues at full
                      speed.
```

Logs are non-critical. Serving traffic is critical. The trade-off is
the right one for an edge proxy.

## Common queries

### Prometheus

```promql
# Request rate per status code
sum by (code) (rate(traefik_service_requests_total[5m]))

# 5xx error ratio
sum(rate(traefik_service_requests_total{code=~"5.."}[5m]))
  / sum(rate(traefik_service_requests_total[5m]))

# Cert days until expiry
(traefik_tls_certs_not_after - time()) / 86400

# Per-container memory working set
container_memory_working_set_bytes{name!=""}

# Host filesystem usage
1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}
     / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})
```

### Loki (LogQL)

```logql
# All Traefik 5xx access logs
{job="traefik", source="access", status=~"5.."}

# Logs from a specific container
{stack="edgeproxy", container="traefik"} |= "error"

# Logs across the stack with a level
{stack="edgeproxy"} | json | level="error"

# Request rate per route from access logs
sum by (router) (rate({job="traefik", source="access"}[1m]))
```

## Disabling individual components

The `monitoring` profile activates all seven services as a unit. To
run a subset:

- Edit
  [`docker-compose.monitoring.yml`](../docker-compose.monitoring.yml)
  and remove the services you don't want.

- Or use a `docker-compose.override.yml` to set `replicas: 0` on
  unwanted services.

If you want **just metrics, no logs**: remove `loki` + `promtail` from
the monitoring overlay. Grafana will still work for Prometheus
dashboards.

If you want **just logs, no metrics**: remove `prometheus` +
`alertmanager` + `node-exporter` + `cadvisor`. Grafana works for
Loki Logs Explorer.
