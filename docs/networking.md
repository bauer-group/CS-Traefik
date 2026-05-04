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

Both networks use Carrier-Grade-NAT (CGNAT) IPv4 ranges and ULA IPv6
ranges to avoid clashing with typical RFC1918 LANs:

| Network | IPv4 subnet | IPv6 subnet |
| --- | --- | --- |
| `EDGEPROXY` (public) | `100.65.0.0/16` | `fdff:100:65::/64` |
| `EDGEPROXY-INTERNAL` | `100.64.0.0/16` | `fdff:100:64::/64` |

These are private to the Docker host — app stacks see them only
inside the Docker network namespace. External traffic enters via
the public port mappings on the Traefik container.

The `100.64.0.0/10` range (RFC 6598) is reserved for CGNAT and is
guaranteed not to conflict with any consumer ISP's LAN allocation.
The `fdff:...` IPv6 range is ULA (RFC 4193) — the IPv6 equivalent of
RFC1918.

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

## Why CGNAT subnets for the Docker networks?

Container networks normally use `172.17.0.0/16` (default Docker bridge)
or `172.18.0.0/16`-`172.31.0.0/16` (additional bridges). These are in
RFC1918 — the same range as many corporate LANs.

If your Docker host is on a `172.18.0.0/16` LAN, Docker's auto-
allocation might pick the same range and break LAN routing. By pinning
CS-Traefik to `100.64.0.0/16` and `100.65.0.0/16` (CGNAT), we
guarantee no collision.

Override per-deployment if you have a specific allocation policy:

```yaml
# In docker-compose.yml network definition:
networks:
  proxy:
    ipam:
      config:
        - subnet: 192.168.250.0/24    # your custom allocation
          gateway: 192.168.250.1
```

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
