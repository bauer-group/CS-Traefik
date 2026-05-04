# Backup & Restore

What `traefik.sh backup` archives, how to restore, and what's NOT in
the backup (because it doesn't need to be).

## What's in the backup

```bash
sudo /opt/edgeproxy/traefik.sh backup
```

Creates a `.tar.gz` at:

```text
${DATA_DIRECTORY}/backups/edgeproxy_YYYYMMDD_HHMMSS.tar.gz
```

The archive contains:

| Path | Why |
| --- | --- |
| `.env` | Configuration. Without this, the stack can't be re-deployed identically. |
| `config/` | Static + dynamic Traefik config, Prometheus rules, Grafana provisioning, Loki / Promtail / Alertmanager configs. |
| `traefik/letsencrypt/` | ACME state — issued certificates and the account key. Without this, all certs would re-issue (rate-limit risk). |
| `traefik/logs/` | Access logs + Traefik server logs (last rotated set). |
| `grafana/` | SQLite DB with users, sessions, dashboard customisations. |
| `prometheus/` | TSDB blocks — historical metrics. **Excluded**: `wal/` (replays from the most recent block on restart). |
| `alertmanager/` | Alert state (silences, inhibits, notifications). |

Excluded:

- `loki/chunks/` — too large, considered ephemeral. Logs older than
  retention are gone anyway.
- `promtail/` — just position file, regenerates on restart.
- Docker images themselves — re-pull on restore.

## Where backups go

Default: `${DATA_DIRECTORY}/backups/`. This lives on the same disk as
the rest of the runtime data.

For real disaster recovery, **copy backups off-host**:

```bash
# Add to root crontab: weekly off-host copy
0 5 * * 0 rsync -a /opt/edgeproxy/backups/ backup-host:/backups/edgeproxy/
```

Or push to S3:

```bash
aws s3 sync /opt/edgeproxy/backups/ s3://my-backups/edgeproxy/
```

The backups are gitignored — they never end up in the repository.

## Backup frequency

There's no automated schedule shipped with CS-Traefik. Set it up via
host cron:

```cron
# /etc/cron.d/edgeproxy-backup
0 4 * * * root /opt/edgeproxy/traefik.sh backup >> /var/log/edgeproxy-backup.log 2>&1
```

Daily 04:00. Adjust to your retention policy.

For old-backup cleanup, add a one-liner:

```cron
30 4 * * * root find /opt/edgeproxy/backups/ -name 'edgeproxy_*.tar.gz' -mtime +30 -delete
```

Keeps the last 30 days.

## Restore

There's no `traefik.sh restore` command — the restore flow is manual
because every situation is different (full host rebuild vs. partial
config recovery vs. accidental rm vs. a single corrupted file).

### Full restore (host rebuild)

After re-installing CS-Traefik on a fresh host:

```bash
# 1. Stop the freshly-started stack
sudo /opt/edgeproxy/traefik.sh stop

# 2. Extract the backup over the install dir + data dir
sudo tar -xzf /path/to/edgeproxy_20260504_040000.tar.gz \
     -C /opt/edgeproxy/

# This restores .env, config/, and the data subdirectories.

# 3. Fix permissions (the wizard normally handles this)
sudo chmod 600 /opt/edgeproxy/.env
sudo chmod 700 /opt/edgeproxy/traefik/letsencrypt/
sudo chmod 600 /opt/edgeproxy/traefik/letsencrypt/*.json
sudo chown -R 472:472 /opt/edgeproxy/grafana/
sudo chown -R 65534:65534 /opt/edgeproxy/prometheus/
sudo chown -R 65534:65534 /opt/edgeproxy/alertmanager/

# 4. Start the stack
sudo /opt/edgeproxy/traefik.sh start
```

### Partial restore (just `.env`)

```bash
# Extract only .env from the archive
sudo tar -xzf backup.tar.gz .env -O > /opt/edgeproxy/.env
sudo chmod 600 /opt/edgeproxy/.env

sudo /opt/edgeproxy/traefik.sh restart
```

### Partial restore (just ACME certs)

If you nuked `traefik/letsencrypt/` accidentally:

```bash
sudo tar -xzf backup.tar.gz traefik/letsencrypt/ -O > /tmp/letsencrypt.tar
sudo tar -xf /tmp/letsencrypt.tar -C /opt/edgeproxy/
sudo chmod 700 /opt/edgeproxy/traefik/letsencrypt/
sudo chmod 600 /opt/edgeproxy/traefik/letsencrypt/*.json

sudo /opt/edgeproxy/traefik.sh restart
```

Without this, all certs would re-issue on first request — possible
to hit Let's Encrypt's 5 duplicate certs / week rate limit if you
have many certs.

### Partial restore (Grafana dashboards)

Grafana stores user-created dashboards in its SQLite. If someone
accidentally deleted dashboards:

```bash
# Stop just Grafana
docker compose -f /opt/edgeproxy/docker-compose.yml \
               -f /opt/edgeproxy/docker-compose.monitoring.yml \
               --profile monitoring stop grafana

# Extract just the Grafana data
sudo tar -xzf backup.tar.gz grafana/ -O > /tmp/grafana.tar
sudo rm -rf /opt/edgeproxy/grafana/
sudo tar -xf /tmp/grafana.tar -C /opt/edgeproxy/
sudo chown -R 472:472 /opt/edgeproxy/grafana/

# Restart Grafana
docker compose -f /opt/edgeproxy/docker-compose.yml \
               -f /opt/edgeproxy/docker-compose.monitoring.yml \
               --profile monitoring up -d grafana
```

### Partial restore (Prometheus historical metrics)

Prometheus stores compressed time-series blocks. To restore historical
metrics:

```bash
# Stop Prometheus
docker compose -f /opt/edgeproxy/docker-compose.yml \
               -f /opt/edgeproxy/docker-compose.monitoring.yml \
               --profile monitoring stop prometheus

# Extract Prometheus blocks (NOT wal — wal is for the LIVE process)
sudo tar -xzf backup.tar.gz prometheus/ -O > /tmp/prom.tar
sudo rm -rf /opt/edgeproxy/prometheus/
sudo tar -xf /tmp/prom.tar -C /opt/edgeproxy/
sudo chown -R 65534:65534 /opt/edgeproxy/prometheus/

docker compose ... up -d prometheus
```

Prometheus rebuilds the WAL from the latest block on startup. Up to
~2 hours of in-flight metrics may be lost (the WAL window).

## What can NOT be restored from backup

- **Loki chunks** — log data older than `LOKI_RETENTION_PERIOD` (7d
  default) is gone permanently. The backup excludes the chunks dir.
  If long-term log retention matters, configure Loki to ship to S3
  and the chunks live in S3.
- **In-flight requests** at the moment of backup — irrelevant; nothing
  to restore.
- **Container images** — these come from registries. After restore,
  Compose pulls them automatically.
- **Docker volumes** — CS-Traefik uses bind mounts for everything,
  not Docker-managed volumes, so this isn't a concern. Verify with
  `docker volume ls` (should be empty for the edgeproxy project).

## Verifying a backup is good

```bash
# Inspect the archive content
sudo tar -tzf /opt/edgeproxy/backups/edgeproxy_*.tar.gz | head -30

# Should include:
# .env
# config/traefik/...
# traefik/letsencrypt/letsencrypt.json
# grafana/grafana.db
# prometheus/01HABCDE.../meta.json    (numbered blocks)
# alertmanager/silences

# Check size — should be at least a few MB
ls -lh /opt/edgeproxy/backups/

# Don't trust an archive you haven't extracted at least once
mkdir /tmp/restore-test
sudo tar -xzf /opt/edgeproxy/backups/edgeproxy_*.tar.gz -C /tmp/restore-test
ls -la /tmp/restore-test/
sudo rm -rf /tmp/restore-test
```

## Migration via backup

You can use a backup as the migration mechanism — old host's backup
restored on the new host = identical state. See
[`migration-from-v2.md`](migration-from-v2.md) Approach 1 step 5
("optional: copy the legacy ACME storage").

The catch: the legacy v2 stack used a different layout
(`acme.json` at the root vs. `letsencrypt/letsencrypt.json` in the
new layout). Manual cherry-pick of the ACME JSON works:

```bash
sudo cp /path/to/legacy/data/acme.json \
        /opt/edgeproxy/traefik/letsencrypt/letsencrypt.json
sudo chmod 600 /opt/edgeproxy/traefik/letsencrypt/letsencrypt.json
```

The Traefik ACME storage schema is compatible across v2 and v3 — no
re-issuance needed if you copy successfully.
