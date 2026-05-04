# Admin Access

The Traefik dashboard, Grafana, Prometheus, and Alertmanager are
reached through a dedicated `api` entrypoint — never on the public 443
port unless you explicitly opt in.

## TL;DR

```bash
ssh -L 9090:127.0.0.1:9090 user@server

# In your browser:
http://127.0.0.1:9090/dashboard/      # Traefik dashboard
http://127.0.0.1:9090/grafana/        # Grafana (own login on top of BasicAuth)
http://127.0.0.1:9090/prometheus/     # Prometheus
http://127.0.0.1:9090/alertmanager/   # Alertmanager
```

BasicAuth (`API_USERS`) + IP whitelist (`API_WHITELIST`) are always
enforced — defence-in-depth even on loopback.

## The three modes

`API_BIND` and `API_BIND_V6` in `.env` control where the api
entrypoint listens. Pick the mode that matches your operational
context.

### Mode 1 — Localhost only (DEFAULT, most secure)

```env
API_BIND=127.0.0.1
API_BIND_V6=::1
API_HOST=
API_BASE_URL=http://localhost:9090
```

The api entrypoint binds only to loopback. The dashboard is
**invisible** from the public internet, the LAN, or any other host.
Connect via SSH-tunnel:

```bash
ssh -L 9090:127.0.0.1:9090 user@server
```

Pros:
- Smallest attack surface — port 9090 isn't visible on any external
  interface.
- No certificate management — plain HTTP on loopback is fine.
- BasicAuth + IP whitelist still enforced as defence-in-depth.

Cons:
- Operators need SSH access to reach the dashboard.

This is the recommended mode for production. Operators with SSH access
already have everything they need.

### Mode 2 — LAN-accessible

```env
API_BIND=0.0.0.0
API_BIND_V6=::
API_HOST=
API_BASE_URL=http://localhost:9090
```

The api entrypoint binds to all interfaces. Reachable on
`http://<host-ip>:9090/...` from any network the Docker host is on.
BasicAuth + IP whitelist still enforced; no TLS on this entrypoint.

Pros:
- Operators on the LAN can reach the dashboard without SSH.
- Useful for trusted office networks / VPN-connected operators.

Cons:
- Plain HTTP across the LAN — credentials travel unencrypted.
- The IP whitelist becomes critical (BasicAuth alone over HTTP is not
  enough on a network where someone could MITM).

Acceptable for trusted-LAN deployments. **Not** acceptable across the
public internet. For HTTPS-protected LAN access, use mode 3 with a
private FQDN that resolves to the LAN IP.

### Mode 3 — Public FQDN over HTTPS

```env
API_BIND=127.0.0.1
API_BIND_V6=::1
API_HOST=admin.bauer-group.com
API_BASE_URL=https://admin.bauer-group.com
```

In addition to the localhost bind, a second router on `web-secure`
activates with:

- Let's Encrypt TLS for `admin.bauer-group.com`
- BasicAuth (`API_USERS`)
- IP whitelist (`API_WHITELIST`)
- Auto HTTP→HTTPS redirect (a separate router on `web` matches the
  same FQDN and redirects to HTTPS; the IP whitelist is applied to
  the redirect too, so non-whitelisted clients see 403 not 301 —
  no enumeration leak).

Routes available:

```text
https://admin.bauer-group.com/dashboard/      # Traefik
https://admin.bauer-group.com/grafana/        # Grafana
https://admin.bauer-group.com/prometheus/     # Prometheus
https://admin.bauer-group.com/alertmanager/   # Alertmanager
```

Pros:
- HTTPS-protected over the public internet.
- Works for remote operators without SSH.
- Same BasicAuth + IP whitelist as the localhost mode.

Cons:
- A subdomain that hosts no app is exposed (always-on attack surface
  even with whitelist).
- Cert renewal depends on the public web entrypoints staying
  reachable.

**Important constraint**: pick a hostname that hosts **no** application
(e.g. `admin.bauer-group.com`). The bare `Host(${API_HOST})` rule on
the redirect router catches all paths under the FQDN — if you point
this at a hostname that's also serving an app, the admin redirect
router would steal traffic from the app's HTTP router.

The localhost binding (mode 1) is **always active** even in mode 3 —
mode 3 *adds* the public FQDN on top. SSH-tunnel access keeps working.

## Authentication layers

Mode 1 + 2 + 3 all enforce **two** auth layers:

1. **IP whitelist** (`api-whitelist@docker` middleware). Source IP
   must be in `API_WHITELIST`. Otherwise: `403 Forbidden`.
2. **BasicAuth** (`api-auth@docker` middleware). Valid
   username + password from `API_USERS`. Otherwise: `401
   Unauthorized` with a `WWW-Authenticate: Basic realm="..."` prompt.

Grafana is special: only the IP whitelist is enforced at the edge,
because Grafana has its own login session (`GRAFANA_ADMIN_USER` /
`GRAFANA_ADMIN_PASSWORD`). Layering BasicAuth on top of Grafana's
SPA-login would break OAuth / OIDC redirects.

## Two-router model: internal vs external

The admin surface is exposed through **two routers** on the same `api`
entrypoint, evaluated by Traefik in priority order. Only one of them
applies to any given request, depending on the source IP:

| Router | Priority | Source-IP rule | Auth required? | Whitelist? | Used by |
| --- | --- | --- | --- | --- | --- |
| `dashboard-internal` | 200 | `ClientIP(100.64.0.0/16)` OR `ClientIP(fdff:100:64::/64)` | **No** | **No** | Monitoring stack containers on the EDGEPROXY-INTERNAL Docker network |
| `dashboard-local` | 1 (catch-all) | Everything else | **BasicAuth** | **`API_WHITELIST`** | Operators via host loopback / SSH tunnel |
| `dashboard-public` | 200 | `Host(${API_HOST})` on `web-secure` | **BasicAuth** | **`API_WHITELIST`** | Mode-3 only -- public-FQDN access over HTTPS |
| `dashboard-public-http` | 200 | `Host(${API_HOST})` on `web` | (redirect only) | **`API_WHITELIST`** | Mode-3 only -- HTTP -> HTTPS redirect for the admin FQDN |

All four admin routers carry **explicit priorities**, not Traefik's
default rule-length scoring. Implicit scoring is deterministic but
fragile: a cosmetic refactor of the rule string (`||` vs ` || `,
backtick spacing, etc.) silently changes the score and can flip
which router wins. Explicit priorities pin the intent so future
edits cannot shadow each other unexpectedly.

The hierarchy is two-tier on purpose:

- **200** = "intercepts a specific case" -- the internal-network
  bypass, and the admin FQDN. Any plausible default-scored app
  router tops out around ~150, so admin always wins.
- **1** = "literally the fallback." Anyone adding a new router on
  the `api` entrypoint only needs priority >= 2 to take precedence
  cleanly, without having to outguess implicit rule scores.

The split has three concrete benefits:

1. **Monitoring stack always works.** `dashboard-internal` is hardcoded
   to the EDGEPROXY-INTERNAL subnet — operators can never accidentally
   lock the monitoring containers out of the admin surface by setting
   an over-restrictive `API_WHITELIST`. Network membership IS the auth:
   only services we attach to the internal Docker network can send
   from those ranges.

2. **External access stays gated.** Anyone arriving via host loopback,
   public FQDN, or any non-internal source falls through to
   `dashboard-local` and must clear both `API_WHITELIST` AND BasicAuth.
   `API_WHITELIST` policy applies only to external — its scope is
   clearly bounded.

3. **`API_WHITELIST` becomes one source of truth for one concern**
   (external operator access). No drift between "ranges allowed because
   they're trusted operators" and "ranges allowed because the monitoring
   stack is on them."

## IP whitelist values (external access only)

Default in `.env.example`:

```env
API_WHITELIST=127.0.0.1/32, ::1/128, 172.16.0.0/12, 192.168.0.0/16, 10.0.0.0/8
```

This covers:

| CIDR | Meaning |
| --- | --- |
| `127.0.0.1/32` | IPv4 loopback (mode 1) |
| `::1/128` | IPv6 loopback (mode 1) |
| `192.168.0.0/16` | Private LAN -- common SOHO / corporate range |
| `10.0.0.0/8` | Private LAN -- enterprise-allocated |
| `172.16.0.0/12` | Private LAN -- Docker default bridge range |

### Network-trust map

The stack runs two Docker networks with deliberately-distinct trust
levels:

| Network | Subnet | Purpose | Admin-access path |
| --- | --- | --- | --- |
| `EDGEPROXY` (public) | `100.65.0.0/16` + `fdff:100:65::/64` | Customer-facing apps that receive **end-user traffic** via Traefik | **None.** Apps reach Traefik for traffic forwarding only; admin surface is unreachable from this network because (a) `dashboard-internal` rule does not match these CIDRs and (b) `API_WHITELIST` does not include them. A compromised public-side app cannot escalate into the admin API. |
| `EDGEPROXY-INTERNAL` | `100.64.0.0/16` + `fdff:100:64::/64` | Monitoring stack (Prometheus, Grafana, Loki, Promtail, Alertmanager, node-exporter, cAdvisor) | **Auto-allowed** via `dashboard-internal` router. No BasicAuth, no whitelist gate -- network membership IS the trust. |
| Host loopback / LAN / VPN | `127.0.0.1`, `::1`, RFC1918 ranges | Operator (SSH tunnel / direct LAN access) | **Gated** via `dashboard-local`: must be in `API_WHITELIST` AND must clear BasicAuth. |

### Mode 3 (public FQDN) -- add operator IPs

For mode 3 (public FQDN access), add your office / VPN public IPs:

```env
API_WHITELIST=127.0.0.1/32, ::1/128, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, 203.0.113.0/24
```

Where `100.64.0.0/10` is the full CGNAT range (Tailscale / WireGuard
meshes) and `203.0.113.0/24` is your office's public range.

The EDGEPROXY-INTERNAL Docker subnet (`100.64.0.0/16`) is *not* added
here -- it is already handled by the `dashboard-internal` router
without going through `API_WHITELIST` at all.

## BasicAuth credentials

`API_USERS` is htpasswd format with bcrypt. Compose-escape: every `$`
becomes `$$`:

```bash
echo $(htpasswd -nB admin) | sed -e 's/\$/\$\$/g'
```

The wizard does this automatically. To rotate a password manually:

1. Generate a new hash with the command above.
2. Replace `API_USERS=...` in `.env`.
3. `sudo ./traefik.sh restart`

## Multiple admin users

`API_USERS` accepts comma-separated user:hash pairs:

```env
API_USERS=admin:$$2y$$05$$abc...,operator:$$2y$$05$$xyz...
```

Each gets the same access (no role-based granularity at the edge).
For role-based separation, use [`forward-auth-authelia@file`](middlewares.md#forward-auth-authelia)
on the admin routers and let Authelia handle roles.

## Disabling the dashboard entirely

If you have no need for the Traefik dashboard, monitoring profile is
off, and you only care about the public web/web-secure entrypoints,
you can leave `API_BIND` defaulted to `127.0.0.1` and never SSH-tunnel
to it. The dashboard simply never gets reached. Resource cost is
zero (no extra container, just an unused endpoint inside the Traefik
container).

To remove the api entrypoint port mapping completely, edit
[`docker-compose.yml`](../docker-compose.yml) and delete the
`${API_BIND}:${API_PORT}:9090/tcp` + `[${API_BIND_V6}]:${API_PORT}:9090/tcp`
lines. The api entrypoint still exists internally but isn't bound to
any host port.

## Hardening checklist

Before exposing admin access (any mode):

- [ ] `API_USERS` rotated from the default `admin/admin`.
- [ ] `API_WHITELIST` tightened to your specific networks (drop
      `192.168.0.0/16` etc. if you're not actually on a 192.168 LAN).
- [ ] If mode 3: `API_HOST` is a hostname that hosts no app.
- [ ] If mode 3: DNS A/AAAA correct, port 80 reachable for ACME
      HTTP-01 (or DNS-01 configured).
- [ ] `GRAFANA_ADMIN_PASSWORD` rotated from the default `changeme`.
- [ ] `.env` is `chmod 600` (the wizard does this; verify after
      manual edits).
