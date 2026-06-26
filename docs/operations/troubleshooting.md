# Troubleshooting

Symptom → cause → fix. Bookmark this page for incidents.

## First-line diagnosis

Always run these three first — they tell you what's actually broken:

```bash
sudo /opt/edgeproxy/traefik.sh status        # what's running
sudo /opt/edgeproxy/traefik.sh logs traefik  # follow Traefik logs
sudo /opt/edgeproxy/traefik.sh validate      # config syntax check
```

For deep inspection, the dashboard at `http://127.0.0.1:9090/dashboard/`
shows live router/service/middleware state.

## ACME / Let's Encrypt failures

### Symptom: HTTPS returns the Traefik default cert (the scary "TRAEFIK DEFAULT CERT")

```bash
sudo /opt/edgeproxy/traefik.sh logs traefik | grep -i acme
```

Look for:

#### "no such host" / "lookup ... no DNS records"

DNS A/AAAA isn't pointing at your Traefik host. Verify:

```bash
dig +short app.bauer-group.com
dig +short AAAA app.bauer-group.com
```

Should return your Traefik host's public IP.

#### "Connection refused" / "Connection timeout"

Port 80 (HTTP-01) or port 443 (TLS-ALPN-01) isn't reachable from the
public internet. Check:

```bash
# From an external host
curl -v http://app.bauer-group.com/.well-known/acme-challenge/test
```

Common causes: firewall blocking port 80, DNS pointing at the wrong
host, ISP blocking port 80 (residential connections often do — use
DNS-01 instead).

#### "rate limit exceeded"

Hit one of:

- 5 duplicate certs per registered domain per week.
- 50 certs per account per week.
- 300 new orders per account per 3 hours.

Switch the affected router to staging while you debug:

```yaml
- "traefik.http.routers.X.tls.certresolver=letsencrypt-staging"
```

Wait until the rate-limit window expires before re-issuing.

#### "DNS challenge: TXT record not found"

DNS-01 propagation hasn't completed before Traefik checks. Increase
`delayBeforeCheck` in
[`config/traefik/traefik.yml`](../../config/traefik/traefik.yml):

```yaml
letsencrypt-dns:
  acme:
    dnsChallenge:
      delayBeforeCheck: 30s   # bump from 10s
```

Then `sudo ./traefik.sh restart`.

#### "providerName is required"

The DNS-01 resolver is referenced but `LETSENCRYPT_DNS_PROVIDER`
isn't set in `.env`. Set it (e.g. `LETSENCRYPT_DNS_PROVIDER=cloudflare`)
plus the provider's credentials, then restart.

### Symptom: ACME storage file owned by wrong user

```
Unable to store ACME data: open /etc/traefik/certs/letsencrypt/letsencrypt.json: permission denied
```

The mounted directory should be writable by the Traefik process.
`traefik.sh start` enforces `chmod 700` on the directory and `chmod
600` on JSON files. If you ran Traefik manually outside of `traefik
.sh`, ownership might be off:

```bash
sudo chown -R root:root /opt/edgeproxy/data/traefik/letsencrypt/
sudo chmod 700 /opt/edgeproxy/data/traefik/letsencrypt/
sudo chmod 600 /opt/edgeproxy/data/traefik/letsencrypt/*.json
```

Then `sudo ./traefik.sh restart`.

## 502 / 503 errors

### Symptom: 502 Bad Gateway

The backend is unreachable from Traefik.

```bash
# Is the backend container even running?
docker ps | grep myapp

# Is it on the proxy network?
docker network inspect EDGEPROXY -f '{{range .Containers}}{{.Name}}{{println}}{{end}}'

# Can Traefik DNS-resolve the backend?
docker exec edgeproxy-traefik nslookup my-app

# Can Traefik connect to the backend port?
docker exec edgeproxy-traefik wget -qO- http://my-app:3000/health
```

Common causes:

- Backend container down or crashed → `docker compose up -d`.
- Backend not on the `EDGEPROXY` network → check the app's compose
  has `traefik.docker.network=EDGEPROXY` label.
- Wrong port in `traefik.http.services.X.loadbalancer.server.port`
  label — must match the container's `EXPOSE`/`expose:` declaration.
- Backend healthcheck failing → Traefik routes around unhealthy
  containers; if all are unhealthy, all return 502.

### Symptom: 503 Service Unavailable

Traefik has the route but the backend pool is empty (all instances
failing healthcheck) OR a circuit breaker has tripped.

Check:

- `docker compose ps myapp` — service status (healthy/unhealthy).
- Dashboard → HTTP → Services → look for "DOWN" servers.
- If using `circuit-breaker@file` middleware: did backends recently
  return >30% 5xx? Wait `recoveryDuration` (10s default).

### Symptom: 503 with all healthchecks passing

Rate limiter is tripping. Check:

```bash
sudo /opt/edgeproxy/traefik.sh logs traefik | grep -i "rate limit\|throttle"
```

If you applied `rate-limit-strict@file` to a public route by mistake,
legitimate users (especially CGNAT-shared) hit the 10 req/s cap
immediately. Switch to `rate-limit@file` (5000 req/s) or
`rate-limit-permissive@file` (20000 req/s).

## Dashboard / admin access issues

### Symptom: 401 Unauthorized when hitting /dashboard

BasicAuth credentials are wrong or `MONITORING_USERS` isn't formatted right.

Generate fresh:

```bash
echo $(htpasswd -nB admin) | sed -e 's/\$/\$\$/g'
```

Replace `MONITORING_USERS=...` in `.env`, then `sudo ./traefik.sh restart`.

⚠️ The double-`$$` escaping is required because Compose expands
single `$`. If you generated the hash without `sed` post-processing,
Compose substitutes the `$` placeholders and corrupts the hash.

### Symptom: 403 Forbidden when hitting /dashboard

Your apparent source IP isn't in `MONITORING_WHITELIST`. The `403` comes
from the `monitoring-whitelist` middleware (a Traefik IP gate) — *not*
from BasicAuth, which would return `401 Unauthorized`. So if you see
`403`, you already cleared the password; only the IP gate is blocking.

Find the IP Traefik **actually saw** — do not guess it:

```bash
# The ClientHost field on the rejected request is the source IP to allow
docker exec edgeproxy-traefik sh -c \
  "grep '\"entryPointName\":\"monitoring\"' /var/log/traefik/access.log | tail -5"
```

**Accessing via SSH tunnel (mode 1)?** `ClientHost` will be the
proxy-network gateway `100.65.0.1`, *not* `127.0.0.1` — this is expected.
A tunnel request to the host's `127.0.0.1:9090` binding is published into
the Traefik container by `docker-proxy`, which masquerades the source to
the bridge gateway (happens on Linux native too — see
[known-limitations.md](known-limitations.md#source-ip-munging-through-docker-port-forward)).
The shipped default already includes `100.65.0.1/32` for exactly this
reason. If it was removed, re-add it:

```env
MONITORING_WHITELIST=127.0.0.1/32, ::1/128, 100.65.0.1/32
```

**Accessing a public FQDN (mode 3)?** Traffic arrives on 443 with the
real client IP preserved. Check yours and add it:

```bash
curl -s https://api.ipify.org    # public IPv4
curl -s https://api64.ipify.org  # public IPv6
```

```env
MONITORING_WHITELIST=127.0.0.1/32, ::1/128, 100.65.0.1/32, 203.0.113.42/32
```

`sudo ./traefik.sh restart` after editing.

If you're on CGNAT (mobile carrier, dual-stack-lite ISP), your apparent
public IP changes per session — use a VPN with a static egress IP, or
the SSH-tunnel approach (mode 1).

### Symptom: Dashboard at `127.0.0.1:9090/dashboard/` doesn't open

Connection refused or timeout:

```bash
# Is the host port bound?
sudo netstat -tlnp | grep 9090

# Should show 127.0.0.1:9090 -> docker-proxy
```

If not bound, check `docker ps`:

```bash
docker port edgeproxy-traefik
# Should include: 9090/tcp -> 127.0.0.1:9090
```

If it shows `0.0.0.0:9090` instead, your `MONITORING_BIND` is set to `0.0.0.0`
(LAN mode) — that still works for localhost access, just listens
elsewhere too.

If port 9090 is bound but the page doesn't load, check Traefik logs
for routing errors.

### Symptom: Grafana redirects in a loop

Sub-path serving is misconfigured. Verify:

```bash
docker exec edgeproxy-grafana env | grep GF_SERVER
# GF_SERVER_ROOT_URL=http://localhost:9090/grafana
# GF_SERVER_SERVE_FROM_SUB_PATH=true
```

If `GF_SERVER_ROOT_URL` doesn't end with `/grafana` or
`GF_SERVER_SERVE_FROM_SUB_PATH=false`, edit `.env`:

```env
MONITORING_BASE_URL=http://localhost:9090
```

Restart with `sudo ./traefik.sh restart`.

If you set `MONITORING_HOST` (mode 3), the URL changes to
`https://${MONITORING_HOST}/grafana`. Verify `MONITORING_BASE_URL=https://${MONITORING_HOST}`.

## Logging issues

### Symptom: No logs in Loki

```bash
# Promtail is running?
docker ps | grep promtail

# Can it reach Loki?
docker exec edgeproxy-promtail wget -qO- http://loki:3100/ready

# Promtail logs
docker logs edgeproxy-promtail | tail -50
```

If Promtail can't reach Loki: both must be on `EDGEPROXY-INTERNAL`.
Verify:

```bash
docker network inspect EDGEPROXY-INTERNAL -f '{{range .Containers}}{{.Name}}{{println}}{{end}}'
# Should include both promtail and loki
```

### Symptom: Traefik file logs (access.log) not appearing

The bind mount target needs to be writable:

```bash
ls -la /opt/edgeproxy/data/traefik/logs/
# Should show traefik writable here
```

If permissions are wrong, fix:

```bash
sudo mkdir -p /opt/edgeproxy/data/traefik/logs
sudo chmod 755 /opt/edgeproxy/data/traefik/logs
sudo /opt/edgeproxy/traefik.sh restart
```

Note: file logs only appear when `accessLog.filePath` is set in
`traefik.yml` (it is by default). If you commented it out, no file
logs.

### Symptom: Container logs filling up disk

Default per-container log rotation is 50 MB × 5 files = 250 MB max.
For very chatty apps, this might still grow fast.

Lower in `.env`:

```env
LOG_MAX_SIZE=10m
LOG_MAX_FILE=3
```

`sudo ./traefik.sh restart`. Existing rotated files keep accumulating
until the next rotation.

## Performance issues

### Symptom: High CPU on Traefik

```bash
docker stats edgeproxy-traefik
```

If consistently >80 %, either:

- Genuine traffic spike — let it ride; Traefik is uncapped by design.
- Pathological access-log buffering — set
  `accessLog.bufferingSize=200` in traefik.yml (default 100).
- Routing-rule complexity (regex-heavy or many file-provider routes)
  — consolidate where possible.
- Cert rotation churn — each cert renewal is briefly CPU-heavy. Bumps
  every 30 days per cert.

### Symptom: Container OOM-killed

```bash
dmesg | grep -i "killed process"
docker inspect edgeproxy-loki | jq '.[0].State'
```

Check the resource caps in `.env`:

| Service | Default cap |
| --- | --- |
| Prometheus | 4 GB |
| Grafana | 1 GB |
| Loki | 2 GB |
| Promtail | 512 MB |

If your workload exceeds the cap, raise it. Or check for actual leaks:

- Prometheus: cardinality explosion (label-leak in apps).
  ```promql
  topk(10, count by (__name__)({}))
  ```
- Loki: high-cardinality labels in shipped logs.
- Grafana: plugin memory leak — disable third-party plugins.

### Symptom: Slow dashboard / Grafana queries

Likely Prometheus is the bottleneck. Check:

```promql
# How many series does Prometheus track?
prometheus_tsdb_head_series

# Scrape duration p99
histogram_quantile(0.99, sum(rate(prometheus_target_interval_length_seconds_bucket[5m])) by (le))
```

If `head_series > 500_000`, you're on the steep part of the
performance curve. Raise `PROMETHEUS_MEMORY_LIMIT` and consider
identifying the cardinality offender.

## Network issues

### Symptom: App stack can't see EDGEPROXY network

```bash
# Bring up the app
cd /path/to/myapp && docker compose up -d
# Error: network EDGEPROXY declared as external, but could not be found
```

CS-Traefik isn't running yet. Start it first:

```bash
sudo /opt/edgeproxy/traefik.sh start
cd /path/to/myapp && docker compose up -d
```

The `external: true` flag means Compose expects the network to
already exist — it's CS-Traefik's job to create it.

### Symptom: Two services with the same hostname clash

Two app stacks both have routers matching `Host(\`api.bauer-group.com\`)`.
Traefik routes to whichever wins the rule-priority lottery — usually
the more specific one, otherwise indeterminate.

Check the dashboard → HTTP → Routers — both will appear. Pick which
should win, delete the other.

If both are needed for different paths under the same host, add
`PathPrefix(...)` to each:

```yaml
- "traefik.http.routers.A.rule=Host(`api.bauer-group.com`) && PathPrefix(`/v1`)"
- "traefik.http.routers.B.rule=Host(`api.bauer-group.com`) && PathPrefix(`/v2`)"
```

### Symptom: IPv6 client can't reach Traefik

Check both the DNS and the bind:

```bash
# DNS has AAAA?
dig AAAA app.bauer-group.com

# Traefik bound to IPv6?
sudo netstat -tlnp | grep ':80\|:443'
# Should show :::80 and :::443 (the [::] binding)
```

If DNS has no AAAA, IPv6 clients fall back to IPv4 anyway. If
Traefik's not bound to IPv6, your `docker-compose.yml` is missing the
`[::]:` mapping lines.

## Compose / startup issues

### Symptom: `docker compose up` fails with "name conflict"

Two stacks both have a container named `edgeproxy-traefik` (or
similar). Either:

- You ran `traefik.sh start` twice in different `STACK_NAME`s — pick
  one.
- A previous `down` left orphan containers — `docker rm -f $(docker ps -aq --filter name=edgeproxy)`.

### Symptom: Healthcheck fails on Traefik

```bash
docker inspect edgeproxy-traefik -f '{{.State.Health}}'
```

If unhealthy, the `traefik healthcheck --ping` command can't reach
the ping endpoint (port 8081 internally). Almost always means
Traefik failed to start / config error. Check:

```bash
docker logs edgeproxy-traefik | tail -50
```

Look for `ERR` lines pointing at config issues. Common causes: typo
in `traefik.yml`, missing env var, ACME storage permissions wrong.

## When in doubt

- **Reset to known-good**: `sudo ./traefik.sh stop` + `sudo ./traefik.sh start`.
- **Bisect changes**: Did this work before your last `git pull`?
  ```bash
  cd /opt/edgeproxy
  git log --oneline -20
  git diff HEAD~5 HEAD -- docker-compose.yml config/traefik/
  ```
- **Switch to staging cert resolver** during debugging to avoid
  burning Let's Encrypt rate limit:
  ```env
  LETSENCRYPT_CA=https://acme-staging-v02.api.letsencrypt.org/directory
  ```
- **File an issue** at https://github.com/bauer-group/CS-Traefik/issues
  with `traefik.sh logs` output and your `.env` (redact secrets).
