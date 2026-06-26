# Admin Access

The Traefik dashboard, Grafana, Prometheus, and Alertmanager are
reached through a dedicated `monitoring` entrypoint — never on the public 443
port unless you explicitly opt in.

## TL;DR

```bash
ssh -L 9090:127.0.0.1:9090 user@server

# In your browser:
http://127.0.0.1:9090/dashboard/      # Traefik dashboard
http://127.0.0.1:9090/grafana/        # Grafana (BasicAuth at the edge, no second login)
http://127.0.0.1:9090/prometheus/     # Prometheus
http://127.0.0.1:9090/alertmanager/   # Alertmanager
```

BasicAuth (`MONITORING_USERS`) + IP whitelist (`MONITORING_WHITELIST`) are always
enforced — defence-in-depth even on loopback.

## When is port 9090 actually bound?

The host-port binding for `monitoring` (`127.0.0.1:9090` by default) lives
inside `docker-compose.monitoring.yml`, not in the base
`docker-compose.yml`. The reasoning: the only externally-visible
reason to bind 9090 is to reach Grafana / Prometheus / Alertmanager,
which are themselves part of the monitoring overlay. The Traefik
dashboard rides on the same entrypoint, so it ships together with
that bundle.

Bottom line — the `monitoring` profile owns the 9090 binding:

| `COMPOSE_PROFILES` value      | Host port 9090 bound? |
| ----------------------------- | --------------------- |
| _(empty — pure proxy)_        | No                    |
| `auto-update`                 | No                    |
| `monitoring`                  | Yes                   |
| `monitoring,auto-update`      | Yes                   |

The `monitoring` entrypoint itself is always defined inside Traefik
(`config/traefik/traefik.yml`: `monitoring: address: ":9090/tcp"`). It
listens within the container regardless of host binding, so other
containers on the proxy-internal Docker network can still reach
`traefik:9090` directly via Docker DNS.

Mode 3 (public FQDN — see below) is independent of this. Admin UIs
in mode 3 are reached via port 443 with `Host(${MONITORING_HOST})`, which
is part of the base stack and works without the monitoring overlay.

## The three modes

`MONITORING_BIND` and `MONITORING_BIND_V6` in `.env` control where the
`monitoring` entrypoint listens. Pick the mode that matches your operational
context.

### Mode 1 — Localhost only (DEFAULT, most secure)

```env
MONITORING_BIND=127.0.0.1
MONITORING_BIND_V6=::1
MONITORING_HOST=
MONITORING_BASE_URL=http://localhost:9090
```

The monitoring entrypoint binds only to loopback. The dashboard is
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
MONITORING_BIND=0.0.0.0
MONITORING_BIND_V6=::
MONITORING_HOST=
MONITORING_BASE_URL=http://localhost:9090
```

The monitoring entrypoint binds to all interfaces. Reachable on
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
MONITORING_BIND=127.0.0.1
MONITORING_BIND_V6=::1
MONITORING_HOST=admin.bauer-group.com
MONITORING_BASE_URL=https://admin.bauer-group.com
```

In addition to the localhost bind, a second router on `web-secure`
activates with:

- Let's Encrypt TLS for `admin.bauer-group.com`
- BasicAuth (`MONITORING_USERS`)
- IP whitelist (`MONITORING_WHITELIST`)
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
(e.g. `admin.bauer-group.com`). The bare `Host(${MONITORING_HOST})` rule on
the redirect router catches all paths under the FQDN — if you point
this at a hostname that's also serving an app, the admin redirect
router would steal traffic from the app's HTTP router.

The localhost binding (mode 1) is **always active** even in mode 3 —
mode 3 *adds* the public FQDN on top. SSH-tunnel access keeps working.

## Authentication layers

Mode 1 + 2 + 3 all enforce **two** auth layers:

1. **IP whitelist** (`monitoring-whitelist@docker` middleware). Source IP
   must be in `MONITORING_WHITELIST`. Otherwise: `403 Forbidden`.
2. **BasicAuth** (`monitoring-auth@docker` middleware). Valid
   username + password from `MONITORING_USERS`. Otherwise: `401
   Unauthorized` with a `WWW-Authenticate: Basic realm="..."` prompt.

Grafana uses the same edge auth chain as Prometheus / Alertmanager
(`monitoring-auth@docker,monitoring-whitelist@docker`). Grafana's own login UI is
disabled (`GF_AUTH_BASIC_ENABLED=false`,
`GF_AUTH_DISABLE_LOGIN_FORM=true`); the anonymous role is Admin so the
BasicAuth credential is the single auth identity. `GRAFANA_ADMIN_USER`
/ `GRAFANA_ADMIN_PASSWORD` are still seeded for HTTP-API use and
`grafana-cli admin reset-admin-password` recovery, not for UI login.

Inside the `proxy-internal` Docker network, container-to-container
traffic (Grafana → Prometheus / Loki / Alertmanager) bypasses Traefik
entirely via direct DNS — so no auth applies there either, by design.
The internal network is the trust boundary; the edge enforces auth
for human access only.

## Two-router model: internal vs external

The admin surface is exposed through **two routers** on the same `monitoring`
entrypoint, evaluated by Traefik in priority order. Only one of them
applies to any given request, depending on the source IP:

| Router | Priority | Source-IP rule | Auth required? | Whitelist? | Used by |
| --- | --- | --- | --- | --- | --- |
| `dashboard-internal` | 300 | `ClientIP(100.64.0.0/16)` OR `ClientIP(fdff:100:64::/64)` | **No** | **No** | Monitoring stack containers on the EDGEPROXY-INTERNAL Docker network |
| `dashboard-public` | 300 | `Host(${MONITORING_HOST})` on `web-secure` | **BasicAuth** | **`MONITORING_WHITELIST`** | Mode-3 only -- public-FQDN access over HTTPS |
| `dashboard-public-http` | 300 | `Host(${MONITORING_HOST})` on `web` | (redirect only) | **`MONITORING_WHITELIST`** | Mode-3 only -- HTTP -> HTTPS redirect for the admin FQDN |
| `dashboard-local` | 200 (catch-all) | Everything else | **BasicAuth** | **`MONITORING_WHITELIST`** | Operators via host loopback / SSH tunnel |

All four admin routers carry **explicit priorities**, not Traefik's
default rule-length scoring. Implicit scoring is deterministic but
fragile: a cosmetic refactor of the rule string (`||` vs ` || `,
backtick spacing, etc.) silently changes the score and can flip
which router wins. Explicit priorities pin the intent so future
edits cannot shadow each other unexpectedly.

### Three-tier priority hierarchy

- **300** = "must intercept this specific case." Internal-network
  bypass and the admin FQDN sit here. Beats both the catch-all
  admin gate and any app router, regardless of how long an app's
  rule string scores by length.
- **200** = "catch-all admin gate, beats any app." Sits above the
  realistic implicit-priority maximum (~150 for typical apps with
  Host + Path + Method + Headers rules), so an app accidentally
  exposed on the `monitoring` entrypoint cannot bypass the BasicAuth +
  whitelist gate by having a long rule.
- **1 ... ~150** = "everything else." Apps either run with implicit
  scoring (rule-length-based) or set their own explicit priority.

Adding a new router on the `monitoring` entrypoint that should take
precedence over `dashboard-local` (e.g. an additional internal
intercept): priority >= 250. Fully-controlled overrides that need
to beat even the intercepts (test routers, debug paths): 400+.

### Fail-closed for unset `MONITORING_HOST`

When `MONITORING_HOST` is empty in `.env` (the default — modes 1 and 2),
the public-FQDN routers must NOT match any real traffic. The
naive `${MONITORING_HOST:+...}` shell pattern *appears* to do this — when
the variable is empty, the rule string evaluates to empty — but
Traefik then falls back to the docker provider's auto-generated
default rule, and the router silently activates against the
container's name.

The actual fail-closed pattern uses `${MONITORING_HOST:-fallback}` with
a never-match placeholder:

```yaml
traefik.http.routers.dashboard-public.rule:
  Host(`${MONITORING_HOST:-__monitoring_host_not_set__.invalid}`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))
```

When `MONITORING_HOST` is set, the rule expands to the real FQDN. When
unset, it expands to a Host rule pointing at the literal string
`__monitoring_host_not_set__.invalid`. RFC 2606 reserves the `.invalid`
TLD — no DNS entry for any `.invalid` host can ever exist, so no
real client request will arrive with a matching Host header. The
placeholder name itself also serves as documentation: an operator
who sees this rule in the dashboard knows immediately that they
should set `MONITORING_HOST`
in `.env` to enable mode 3.

The pattern is contained in the affected router rules only -- no
global Traefik configuration change. Other apps in the stack are
unaffected.

The split has three concrete benefits:

1. **Monitoring stack always works.** `dashboard-internal` is hardcoded
   to the EDGEPROXY-INTERNAL subnet — operators can never accidentally
   lock the monitoring containers out of the admin surface by setting
   an over-restrictive `MONITORING_WHITELIST`. Network membership IS the auth:
   only services we attach to the internal Docker network can send
   from those ranges.

2. **External access stays gated.** Anyone arriving via host loopback,
   public FQDN, or any non-internal source falls through to
   `dashboard-local` and must clear both `MONITORING_WHITELIST` AND BasicAuth.
   `MONITORING_WHITELIST` policy applies only to external — its scope is
   clearly bounded.

3. **`MONITORING_WHITELIST` becomes one source of truth for one concern**
   (external operator access). No drift between "ranges allowed because
   they're trusted operators" and "ranges allowed because the monitoring
   stack is on them."

## IP whitelist values (external access only)

Default in `.env.example`:

```env
MONITORING_WHITELIST=127.0.0.1/32, ::1/128, 100.65.0.1/32
```

This covers:

| CIDR | Meaning |
| --- | --- |
| `127.0.0.1/32` | IPv4 loopback |
| `::1/128` | IPv6 loopback |
| `100.65.0.1/32` | `proxy`-network gateway -- the source IP Traefik sees for SSH-tunnel access. `docker-proxy` masquerades the tunnel's `127.0.0.1` to this gateway, so without it the documented mode-1 tunnel returns `403 Forbidden`. See [known-limitations.md](operations/known-limitations.md#source-ip-munging-through-docker-port-forward). |

Add private LAN ranges (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`)
or your office public range only as you actually need them — do not
pre-add "just in case."

### Network-trust map

The stack runs two Docker networks with deliberately-distinct trust
levels:

| Network | Subnet | Purpose | Admin-access path |
| --- | --- | --- | --- |
| `EDGEPROXY` (public) | `${PROXY_SUBNET:-172.30.65.0/16}` + `${PROXY_SUBNET_V6:-fdff:30:65::/64}` | Customer-facing apps that receive **end-user traffic** via Traefik | **None.** Apps reach Traefik for traffic forwarding only; admin surface is unreachable from this network because (a) `dashboard-internal` rule does not match these CIDRs and (b) `MONITORING_WHITELIST` does not include them. A compromised public-side app cannot escalate into the admin API. |
| `EDGEPROXY-INTERNAL` | `${INTERNAL_SUBNET:-172.30.64.0/16}` + `${INTERNAL_SUBNET_V6:-fdff:30:64::/64}` | Monitoring stack (Prometheus, Grafana, Loki, Promtail, Alertmanager, node-exporter, cAdvisor) | **Auto-allowed** via `dashboard-internal` router. No BasicAuth, no whitelist gate -- network membership IS the trust. |
| Host loopback / LAN / VPN | `127.0.0.1`, `::1`, RFC1918 ranges | Operator (SSH tunnel / direct LAN access) | **Gated** via `dashboard-local`: must be in `MONITORING_WHITELIST` AND must clear BasicAuth. |

### Mode 3 (public FQDN) -- add operator IPs

For mode 3 (public FQDN access), add your office / VPN public IPs:

```env
MONITORING_WHITELIST=127.0.0.1/32, ::1/128, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, 203.0.113.0/24
```

Where `100.64.0.0/10` is the full CGNAT range (Tailscale / WireGuard
meshes) and `203.0.113.0/24` is your office's public range.

The EDGEPROXY-INTERNAL Docker subnet (default `172.30.64.0/16`) is
*not* added here -- it is already handled by the `dashboard-internal`
router without going through `MONITORING_WHITELIST` at all.

## BasicAuth credentials

`MONITORING_USERS` is htpasswd format with bcrypt. Compose-escape: every `$`
becomes `$$`:

```bash
echo $(htpasswd -nB admin) | sed -e 's/\$/\$\$/g'
```

The wizard does this automatically. To rotate a password manually:

1. Generate a new hash with the command above.
2. Replace `MONITORING_USERS=...` in `.env`.
3. `sudo ./traefik.sh restart`

## Multiple admin users

`MONITORING_USERS` accepts comma-separated user:hash pairs:

```env
MONITORING_USERS=admin:$$2y$$05$$abc...,operator:$$2y$$05$$xyz...
```

Each gets the same access (no role-based granularity at the edge).
For role-based separation, use [`forward-auth-authelia@file`](middlewares.md#forward-auth-authelia)
on the admin routers and let Authelia handle roles.

## Disabling the dashboard entirely

Pure-proxy installs (empty `COMPOSE_PROFILES`) automatically have no
host port for the `monitoring` entrypoint — the binding lives in
`docker-compose.monitoring.yml` and is only loaded with the
monitoring profile. The entrypoint still LISTENS inside the
container (so containers on the proxy-internal network can talk to
Traefik via `traefik:9090`), but nothing on the host can reach it.
Zero resource cost, zero exposed surface. No file edits required.

If you DO have monitoring on but want to drop the host binding
anyway (e.g. you only access admin UIs via mode 3 / public FQDN),
remove the `traefik.ports:` block from
[`docker-compose.monitoring.yml`](../docker-compose.monitoring.yml)
in a `docker-compose.override.yml` overlay rather than editing the
shipped file.

## Hardening checklist

Before exposing admin access (any mode):

- [ ] `MONITORING_USERS` rotated from the default `admin/admin`.
- [ ] `MONITORING_WHITELIST` tightened to your specific networks (drop
      `192.168.0.0/16` etc. if you're not actually on a 192.168 LAN).
- [ ] If mode 3: `MONITORING_HOST` is a hostname that hosts no app.
- [ ] If mode 3: DNS A/AAAA correct, port 80 reachable for ACME
      HTTP-01 (or DNS-01 configured).
- [ ] `GRAFANA_ADMIN_PASSWORD` is set to a strong value (the wizard
      generates one; compose fails closed if it is missing).
- [ ] `.env` is `chmod 600` (the wizard does this; verify after
      manual edits).
