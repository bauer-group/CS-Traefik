# Networking

How CS-Traefik wires Docker networks, host port bindings, and
IPv4 + IPv6 dual-stack reachability.

## Two Docker networks

| Network | Default name | Driver | Reachable from | Purpose |
| --- | --- | --- | --- | --- |
| Public | `EDGEPROXY` | `bridge` (IPv4 + IPv6) | host + Docker network | App stacks attach here as `external: true` to be discovered by Traefik. |
| Internal | `EDGEPROXY-INTERNAL` | `bridge` (IPv4 + IPv6) | Docker network only | Traefik ↔ monitoring stack chatter. App stacks should NOT attach here. |

Override the names via `NETWORK_NAME=...` in `.env`. The internal
network is always the public name + `-INTERNAL` suffix.

### Subnets

Both networks use RFC1918 high-end IPv4 ranges (172.30 / 172.31) and
ULA IPv6 ranges. Defaults are env-overridable for hosts where these
collide with something else:

| Network | IPv4 subnet | IPv6 subnet | Override env var |
| --- | --- | --- | --- |
| `EDGEPROXY` (public) | `172.30.65.0/16` | `fdff:30:65::/64` | `PROXY_SUBNET` / `PROXY_SUBNET_V6` |
| `EDGEPROXY-INTERNAL` | `172.30.64.0/16` | `fdff:30:64::/64` | `INTERNAL_SUBNET` / `INTERNAL_SUBNET_V6` |

These are private to the Docker host — app stacks see them only
inside the Docker network namespace. External traffic enters via
the public port mappings on the Traefik container.

172.16.0.0/12 (RFC1918) is the typical Docker bridge range; we pick
the high end (172.30 / 172.31) to leave 172.17 .. ~172.20 for
Docker's auto-allocated bridges. The `fdff:...` IPv6 range is ULA
(RFC 4193) — the IPv6 equivalent of RFC1918.

**Why these defaults changed in v0.10:** the legacy v2 stack used
CGNAT (`100.64.0.0/16` + `100.65.0.0/16`). CGNAT is technically the
"safest" range against ISP-LAN clashes, but in practice the entire
`100.64.0.0/10` range is claimed by Tailscale (every Tailscale-
enabled host) and is also frequently allocated by Hetzner Cloud
Networks. v3 picks RFC1918 high-end so the defaults work on the
common production case (Tailscale + cloud). If your environment
specifically requires CGNAT or a different RFC1918 range, override
via `PROXY_SUBNET` / `INTERNAL_SUBNET` in `.env`.

## App stack network attachment

App stacks join the public `EDGEPROXY` network as **external**:

```yaml
# any-service/docker-compose.yml
services:
  myapp:
    image: ...
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=EDGEPROXY"
      # ... router + service labels
    networks:
      - proxy

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-EDGEPROXY}
```

Notes:

- `external: true` means Compose won't try to create the network — it
  expects CS-Traefik to have created it. Start CS-Traefik first.
- The `name:` field MUST match `NETWORK_NAME` from CS-Traefik's `.env`.
  The `${PROXY_NETWORK:-EDGEPROXY}` pattern lets each app's `.env`
  override per-deployment without touching the compose file.
- The `traefik.docker.network=EDGEPROXY` label tells Traefik which IP
  to forward to when the container has multiple network attachments.
  This is required when an app is on multiple networks (e.g. its own
  internal network + the proxy).

## Host port bindings

Traefik binds these host ports:

| Port | Protocol | Bind | Purpose |
| --- | --- | --- | --- |
| `${HTTP_PORT}` (default 80) | TCP | `0.0.0.0` + `[::]` | Public HTTP |
| `${HTTPS_PORT}` (default 443) | TCP | `0.0.0.0` + `[::]` | Public HTTPS (HTTP/1.1 + HTTP/2) |
| `${HTTPS_PORT}` (default 443) | UDP | `0.0.0.0` + `[::]` | Public HTTPS (HTTP/3 / QUIC) |
| `${API_PORT}` (default 9090) | TCP | `${API_BIND}` + `[${API_BIND_V6}]` | Admin entrypoint (default loopback only) |

Every public port has **two** explicit bindings — one for IPv4
(`0.0.0.0:`) and one for IPv6 (`[::]:`). This is intentional:
Compose's bare `80:80` syntax binds only to `0.0.0.0` (IPv4) by
default, and dual-stack via `[::]` is config-dependent (some kernels
auto-dual-stack via `IPV6_V6ONLY=0`, others don't).

Explicit beats clever — having both bindings means behaviour is
portable across kernels and Docker versions.

## IPv4 + IPv6 considerations

Modern deployments need **both** stacks:

- Mobile carriers (Telekom, Vodafone, T-Mobile US, ...) hand out IPv6
  to clients alongside IPv4 via NAT64 / 464XLAT.
- Cloud providers (AWS, GCP, Azure) provide both.
- Dual-stack-lite ISPs (German Vodafone Kabel, German Unitymedia, ...)
  give customers IPv6 as the primary with IPv4 via CGNAT.

If you bind only IPv4, IPv6-only clients can't reach you (rare today,
common in the next 5 years). If you bind only IPv6, you cut off
older devices and many corporate networks.

CS-Traefik binds both by default. The container's IPv6 networking is
enabled via `enable_ipv6: true` on the network definition.

## Subnet override

The defaults (`172.30.64.0/16` + `172.30.65.0/16`) suit the common
case but **collide on hosts that already use those ranges**. Typical
collision sources:

- **Tailscale** — claims all of `100.64.0.0/10` (CGNAT). v2's CGNAT
  defaults broke on every Tailscale host; v3's 172.30 defaults avoid
  it.
- **Hetzner Cloud Networks** — operator-defined network ranges,
  often inside 10.0.0.0/8 or 100.64.0.0/10.
- **Default Docker bridges** — `172.17.0.0/16` (`bridge`) and
  `172.18.0.0/16` .. `~172.20.0.0/16` (additional user-defined
  bridges). The 172.30 default leaves these alone.
- **Corporate LAN** — typical 192.168.0.0/16 + 10.0.0.0/8.

If `traefik.sh start` fails with `Pool overlaps with other one on
this address space`, override in `.env`:

```env
# Pick a /16 inside RFC1918 nothing else on this host uses.
# 172.16-31, 192.168, 10/8 are all valid. Avoid the ranges used by
# the collisions above.
PROXY_SUBNET=192.168.250.0/24
PROXY_SUBNET_V6=fdff:192:250::/64
INTERNAL_SUBNET=192.168.249.0/24
INTERNAL_SUBNET_V6=fdff:192:249::/64
```

The `dashboard-internal` router's ClientIP rule (the network-trust
shortcut for the monitoring stack) reads the same env vars, so a
subnet override stays consistent across the stack — no need to
hand-edit the compose file.

## Internal network isolation

The `EDGEPROXY-INTERNAL` network has `internal: false` (the Docker
default). It has its own subnet but is reachable from the host via
Docker DNS just like the public network.

`internal: true` would isolate it completely (no outbound from
containers on it). We don't use that because Traefik on the public
network needs to reach Prometheus/Grafana on the internal network
without bridging both networks per-service. The current design has
Traefik attach to BOTH networks — public for inbound traffic, internal
for outbound to monitoring stack.

If you want stricter internal isolation, set `internal: true` on the
`EDGEPROXY-INTERNAL` definition. The monitoring services then can't
make outbound HTTP calls (e.g. Grafana plugins won't fetch from
grafana.com on first install). Tighter security at the cost of
plugin-discovery convenience.

## Pre-allocated DNS names (inside the Docker network)

Inside the Docker network, services resolve to each other by their
`hostname:` field:

| Inside-network DNS | Service | Network |
| --- | --- | --- |
| `traefik` | Traefik | both |
| `prometheus` | Prometheus | EDGEPROXY-INTERNAL |
| `grafana` | Grafana | EDGEPROXY-INTERNAL |
| `loki` | Loki | EDGEPROXY-INTERNAL |
| `promtail` | Promtail | EDGEPROXY-INTERNAL |
| `alertmanager` | Alertmanager | EDGEPROXY-INTERNAL |
| `node-exporter` | node-exporter | EDGEPROXY-INTERNAL |
| `cadvisor` | cAdvisor | EDGEPROXY-INTERNAL |
| `watchtower` | Watchtower | EDGEPROXY-INTERNAL |

App services on the `EDGEPROXY` network reach other app services on
the same network by their compose-defined hostnames or service names
(e.g. `documenso-server`, `minio-server`).

## Verifying the network setup

After `traefik.sh start`:

```bash
# Public network
docker network inspect EDGEPROXY

# Internal network
docker network inspect EDGEPROXY-INTERNAL

# Which containers are on the public network?
docker network inspect EDGEPROXY -f '{{range .Containers}}{{.Name}} {{end}}'

# Test internal DNS resolution from inside Traefik
docker exec edgeproxy-traefik nslookup prometheus
```

A correct setup shows:

- `EDGEPROXY` contains `edgeproxy-traefik` plus any app stack
  containers that have attached.
- `EDGEPROXY-INTERNAL` contains `edgeproxy-traefik` plus the
  monitoring services (when the `monitoring` profile is active).

## Common questions

**Q: Can I use the legacy underscore name `EDGEPROXY_INTERNAL`?**

A: No — Compose v2 doesn't allow `_` in network names. The legacy v2
stack used `_INTERNAL` because it was raw Docker; CS-Traefik is
Compose-native. App stacks don't reference the internal network
anyway, so this is invisible to you.

**Q: My app stack is on a different host. How does it join EDGEPROXY?**

A: It can't — Docker bridges are host-local. For multi-host
deployments, use a Docker overlay network (Swarm-mode) or a service-
mesh layer (Tailscale, Cilium, ...). The current CS-Traefik design
assumes single-host.

**Q: What happens if Traefik restarts? Do app stacks lose connectivity?**

A: No. The `EDGEPROXY` network persists across Traefik restarts (it's
defined as `external: true` from the app's perspective). Apps stay
attached. Traefik re-discovers them on startup.
