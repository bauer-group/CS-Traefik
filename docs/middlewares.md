# Middlewares

Full catalog of middlewares shipped in
[`config/traefik/dynamic/middlewares.yml`](../config/traefik/dynamic/middlewares.yml).
Reference any of them from app router labels with the `@file` suffix:

```yaml
labels:
  - "traefik.http.routers.myapp.middlewares=hsts@file,nosniff@file"
```

Multiple middlewares can be chained — they execute in the order
listed.

## Design philosophy

The reverse proxy is **not** the right place to enforce app-level
policy. HSTS preload, Permissions-Policy, frame-deny, rate-limits etc.
all have semantics that depend on the specific application:

- A payment flow needs different headers than a static-asset CDN.
- An SSE-streaming dashboard breaks under naive compression.
- An OAuth callback endpoint needs `Cross-Origin-Opener-Policy:
  unsafe-none`.
- A WebSocket app may need a longer idle timeout than the default 180s.

This stack ships **atomic, opt-in middlewares**. Apps choose what
they need; the proxy applies nothing globally to app traffic except
the BAUER GROUP `bg-provider` identification header (entrypoint-level,
non-negotiable).

## Always-on (entrypoint-level)

### `bg-provider`

Wired into `entryPoints.web.http.middlewares` and
`entryPoints.web-secure.http.middlewares` in `traefik.yml`. Runs on
**every public response**, before any router-level middleware. Apps
cannot opt out.

**What it does**: adds `X-Solution-Provider: BAUER GROUP` to the
response. Response-side only — adding it on the request side would
just tell the backend about the proxy (pointless; the backend is
already in our control). The point is to mark traffic *leaving* the
proxy back to the client. Compliance / branding requirement, not a
security boundary.

```yaml
bg-provider:
  headers:
    customResponseHeaders:
      X-Solution-Provider: "BAUER GROUP"
```

## Security headers

| Middleware | What it sets | When |
| --- | --- | --- |
| `hsts` | `Strict-Transport-Security: max-age=63072000; includeSubDomains` | Modern HTTPS-only sites with no legacy mixed-content concern. |
| `hsts-mild` | `Strict-Transport-Security: max-age=31536000` | Sites that share a parent domain with non-HTTPS siblings. |
| `frame-deny` | `X-Frame-Options: DENY` | Most apps. Prevents clickjacking. |
| `frame-sameorigin` | `X-Frame-Options: SAMEORIGIN` | Apps that legitimately use same-origin iframes. |
| `nosniff` | `X-Content-Type-Options: nosniff` | Always safe. Prevents MIME-sniff-based XSS. |
| `referrer-strict` | `Referrer-Policy: strict-origin-when-cross-origin` | Most apps. |
| `referrer-noreferrer` | `Referrer-Policy: no-referrer` | Tighter -- no Referer header sent at all. |
| `permissions-deny` | `Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()` | Apps that don't need any of these powerful APIs. |
| `server-scrub` | Strips `Server` and `X-Powered-By` response headers | Mild obscurity hardening. Combine with `bg-provider` to replace upstream identification. |

## CORS

CORS is browser-enforced policy. Servers signal allowed origins via
response headers; browsers enforce on cross-origin XHR / fetch /
WebSocket. Public APIs and font CDNs often need permissive CORS;
session-bearing apps need carefully-scoped CORS.

### `cors-permissive`

Allow all origins, no credentials. OK for public read-only APIs,
font hosts, static asset hosts. **Not OK** for anything carrying
cookies / auth — CORS spec forbids `*` origin combined with
`Access-Control-Allow-Credentials: true` (browsers reject the
response).

### `cors-credentials`

Template for credentials-bearing CORS. Replace the origin list with
your specific allowed origins:

```yaml
cors-credentials:
  headers:
    accessControlAllowOriginList:
      - "https://app.example.com"
      - "https://admin.example.com"
    accessControlAllowMethods: [GET, POST, PUT, DELETE, PATCH, OPTIONS]
    accessControlAllowHeaders: [Authorization, Content-Type, X-Requested-With]
    accessControlAllowCredentials: true
    accessControlMaxAge: 3600
    addVaryHeader: true
```

## Rate limiting

| Middleware | Average | Burst | Use |
| --- | --- | --- | --- |
| `rate-limit` | 5 000 / s | 10 000 | Default for public web apps. CGNAT-tolerant. |
| `rate-limit-permissive` | 20 000 / s | 40 000 | Heavy-CGNAT markets, S3 multipart with high concurrency. |
| `rate-limit-strict` | 10 / s | 20 | **Only behind IP whitelist** -- brute-force protection. |

Source IP aggregation: IPv6 is aggregated to `/64` (one customer's
whole IPv6 block counts as one bucket). Without this, an IPv6 client
could trivially evade rate-limits by rotating through their own /64.

**CGNAT considerations**: Mobile carriers, dual-stack-lite ISPs, and
corporate egress networks share a single IPv4 across hundreds-to-
thousands of subscribers. The 5000 req/s default is sized to absorb
realistic CGNAT egress spikes (5k users each loading a 50-asset page =
250k burst from one IP). Tighter limits hit legitimate users before
attackers.

A residential single-IP attacker is bounded by their own upstream
(~10k small req/s on a 100 Mbps DSL), so these limits still cap the
single-IP attack vector. Distributed (botnet) floods need anti-DDoS
at the provider / CDN level.

## Body size limits

⚠️ **Applying any of these middlewares enables Traefik's buffering
behaviour** for that route. Without these middlewares, Traefik streams
request and response bodies directly without buffering — which is
what you want for S3, MinIO, large uploads, SSE, video streams.

Use these only on routes where you want to **enforce** a cap:

| Middleware | Cap | Use |
| --- | --- | --- |
| `body-limit-1mb` | 1 MB | Form submissions, small JSON APIs. |
| `body-limit-10mb` | 10 MB | Larger API payloads, JSON imports, CSV uploads. |
| `body-limit-100mb` | 100 MB | Generous but still bounded. |

For unlimited streaming (S3, video, large file servers): **don't apply
any body-limit middleware**. That's the default.

## Resilience

### `retry`

Retries up to 3 times with exponential backoff (100 ms initial, 1 s
cap). **Only retries idempotent methods** (GET / HEAD / OPTIONS / PUT
/ DELETE) by default — non-idempotent (POST / PATCH) is never retried
because the request might have side effects.

### `retry-aggressive`

5 attempts, 50 ms initial backoff. For read-heavy APIs / static asset
proxies where transient failures are expected.

### `circuit-breaker`

Trips when more than 30 % of recent requests return 5xx (within a 10 s
window). Tripped breaker returns 503 immediately for `fallbackDuration`
(10 s), then half-opens for `recoveryDuration` (10 s) to test before
closing fully.

```yaml
circuit-breaker:
  circuitBreaker:
    expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.30"
    checkPeriod: 10s
    fallbackDuration: 10s
    recoveryDuration: 10s
```

Protects backends from being hammered when they're already failing
(escalating cascade prevention).

### `circuit-breaker-strict`

Trips at 10 % errors, 30 s fallback / recovery. For tighter SLA apps.

## Domain canonicalization

### `redirect-strip-www`

Redirects `www.example.com` → `example.com`. Apply on a router that
matches `Host(\`www.example.com\`)`.

### `redirect-add-www`

Opposite: `example.com` → `www.example.com`. Apply on a router that
matches `Host(\`example.com\`)`.

## Forward auth (SSO)

Forward-auth delegates authentication to an external service. Traefik
makes a sub-request to the auth service for each incoming request; if
the auth service returns 200, the request is forwarded to the backend.
If 401, the user is redirected to the auth service's login.

These templates assume Authelia / Authentik are running on the
internal proxy network with the documented hostnames. Adjust per your
deployment.

### `forward-auth-authelia`

```yaml
forward-auth-authelia:
  forwardAuth:
    address: "http://authelia:9091/api/verify?rd=https://auth.example.com"
    trustForwardHeader: true
    authResponseHeaders:
      - Remote-User
      - Remote-Groups
      - Remote-Name
      - Remote-Email
```

See [`examples/forward-auth-authelia.md`](examples/forward-auth-authelia.md)
for a full setup.

### `forward-auth-authentik`

Pre-wired for [Authentik](https://goauthentik.io/) outpost.

## Path manipulation

### `strip-prefix-api`

Strips `/api` from the request path. Useful for routing public
`/api/v1/users` to an internal `/v1/users`. The prefix is hardcoded as
an example; copy and override per-router with your specific prefix.

## Compression

### `compression`

Honours `Accept-Encoding` from the client. Excludes types that
should not be compressed (Server-Sent Events, already-compressed
media):

```yaml
compression:
  compress:
    excludedContentTypes:
      - text/event-stream
      - image/jpeg
      - image/png
      - image/webp
      - video/mp4
      - application/zip
    minResponseBodyBytes: 1024
```

Don't apply to login / authenticated form endpoints — BREACH attack
class.

## Auth helpers

### `strip-auth`

Strips the `Authorization` header from the request before forwarding
to the backend. Useful when BasicAuth is enforced at the edge but the
upstream service doesn't expect (and might mishandle) an Authorization
header.

## Redirects

### `https-redirect`

Per-router HTTP → HTTPS redirect. Each app owns this decision (no
global entrypoint redirect by design — app stacks may have HTTP-only
routes for webhooks / IoT / health probes / ACME-self-hosted / etc.).

```yaml
labels:
  - "traefik.http.routers.myapp-http.rule=Host(`app.example.com`)"
  - "traefik.http.routers.myapp-http.entrypoints=web"
  - "traefik.http.routers.myapp-http.middlewares=https-redirect@file"
```

## Pre-composed chains

Starting points for common scenarios. Apply with:

```yaml
- "traefik.http.routers.foo.middlewares=hardened-public@file"
```

| Chain | Includes | When |
| --- | --- | --- |
| `hardened-public` | `compression + hsts + frame-deny + nosniff + referrer-strict + server-scrub + rate-limit` | Public web app, modern browser audience. **Not for SSE / streaming** -- compression breaks SSE. |
| `hardened-api` | `hsts-mild + nosniff + server-scrub + rate-limit + body-limit-10mb` | API backend with sensible body cap. |
| `s3-streaming` | `rate-limit-permissive + server-scrub` | MinIO / S3 / large-file endpoints. **No buffering / body-limit** -- streaming is the default. |
| `hardened-login` | `hsts + frame-deny + nosniff + referrer-noreferrer + server-scrub + rate-limit-strict` | Login / auth endpoints. **No compression** (BREACH). |

## Custom middlewares (file provider)

Drop your own `*.yml` into [`config/traefik/dynamic/`](../config/traefik/dynamic/)
to define project-specific middlewares. Files are picked up live (the
file provider has `watch: true`).

See [`custom-config.md`](custom-config.md) for the file-provider
pattern and [`examples/on-prem-vm-via-file-provider.md`](examples/on-prem-vm-via-file-provider.md)
for a worked example.
