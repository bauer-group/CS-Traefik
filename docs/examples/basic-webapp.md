# Example: Basic Web App

The simplest sensible pattern — a public-facing web app with HTTPS,
HSTS, and per-router HTTP→HTTPS redirect. Drop-in compatible with
the legacy v2 EDGEPROXY stack.

## Compose

```yaml
# any-app/docker-compose.yml
name: ${STACK_NAME:-myapp}

services:

  myapp:
    image: nginx:alpine
    container_name: ${STACK_NAME:-myapp}-server
    restart: unless-stopped

    expose:
      - 8080/tcp

    labels:
      - "traefik.enable=true"

      # ── Per-app HTTP→HTTPS redirect middleware ──
      # Defining the middleware here (not pulling https-redirect@file)
      # keeps the redirect scoped to this app's domain only -- fine-
      # grained control if you ever need to allow HTTP for a specific
      # path under the same hostname.
      - "traefik.http.middlewares.${STACK_NAME:-myapp}-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.${STACK_NAME:-myapp}-https-redirect.redirectscheme.permanent=true"

      # ── HTTP router (port 80) → redirect to HTTPS ──
      - "traefik.http.routers.${STACK_NAME:-myapp}-http.rule=Host(`${SERVICE_HOSTNAME}`)"
      - "traefik.http.routers.${STACK_NAME:-myapp}-http.entrypoints=web"
      - "traefik.http.routers.${STACK_NAME:-myapp}-http.middlewares=${STACK_NAME:-myapp}-https-redirect"

      # ── HTTPS router (port 443) → forward to backend ──
      - "traefik.http.routers.${STACK_NAME:-myapp}-https.rule=Host(`${SERVICE_HOSTNAME}`)"
      - "traefik.http.routers.${STACK_NAME:-myapp}-https.entrypoints=web-secure"
      - "traefik.http.routers.${STACK_NAME:-myapp}-https.tls=true"
      - "traefik.http.routers.${STACK_NAME:-myapp}-https.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${STACK_NAME:-myapp}-https.service=${STACK_NAME:-myapp}"
      - "traefik.http.routers.${STACK_NAME:-myapp}-https.middlewares=hsts-mild@file,nosniff@file"

      - "traefik.http.services.${STACK_NAME:-myapp}.loadbalancer.server.port=8080"

      - "traefik.docker.network=${PROXY_NETWORK:-EDGEPROXY}"

    networks:
      - proxy

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-EDGEPROXY}
```

## .env

```env
STACK_NAME=myapp
SERVICE_HOSTNAME=app.bauer-group.com
PROXY_NETWORK=EDGEPROXY
```

## Bring up

```bash
cd /opt/myapp
docker compose up -d
```

Verify:

```bash
curl -I http://app.bauer-group.com           # → 301 Location: https://...
curl -I https://app.bauer-group.com          # → 200 OK + Strict-Transport-Security
```

## Why two routers?

- `${STACK_NAME}-http` listens on port 80, matches the same hostname,
  uses the redirect middleware → returns 301 to HTTPS.
- `${STACK_NAME}-https` listens on port 443, terminates TLS (Let's
  Encrypt cert via HTTP-01 challenge on port 80), forwards to the
  app backend.

This is the **per-router redirect pattern** — apps own their redirect.
CS-Traefik does NOT have a global entrypoint redirect (the legacy
EDGEPROXY v2 stack also kept that off, by design — see
[`tls-and-certificates.md`](../tls-and-certificates.md) for why).

## Why the `${STACK_NAME}` prefix on middleware/router names?

Compose merges all stacks' Traefik labels into one logical Traefik
config at runtime. Middleware/router names need to be unique across
the whole proxy, not just within your stack. Prefixing with
`${STACK_NAME}` (like `myapp-https-redirect`) prevents collisions
when you run multiple stacks against the same Traefik.

The `@file` references (like `hsts-mild@file`) come from CS-Traefik's
own [`config/traefik/dynamic/middlewares.yml`](../../config/traefik/dynamic/middlewares.yml) — those are already namespaced.

## What headers get added by default?

Without **any** middleware referenced at the router level, the proxy
still rewrites two response headers via the always-on `bg-provider`
entrypoint middleware:

- `Server: BAUER GROUP Edge`
- `X-Powered-By: BAUER GROUP`

Both are fixed brand values — they advertise the BAUER GROUP-managed
edge *and* mask the real backend (the constant overwrites the
upstream's `nginx`/PHP/Express + version, so scanners can't fingerprint
it). The optional `X-Solution-Provider: BAUER GROUP` header ships
commented-out in `middlewares.yml` — uncomment it if you want it too.

The example above adds two more (opt-in):

- `hsts-mild@file` — `Strict-Transport-Security` for 1 year, no
  subdomain inheritance.
- `nosniff@file` — `X-Content-Type-Options: nosniff`.

For more security, swap `hsts-mild@file,nosniff@file` for
`hardened-public@file` — that pre-composed chain adds compression +
HSTS preload + frame-deny + referrer-policy + rate-limit.

## Variants

### Direct HTTPS without per-app redirect middleware

If you don't care about redirecting HTTP → HTTPS (rare for a public
site, but valid for an HTTPS-only API):

```yaml
labels:
  - "traefik.enable=true"
  # Only HTTPS router; HTTP requests to this hostname → 404
  - "traefik.http.routers.${STACK_NAME}-https.rule=Host(`${SERVICE_HOSTNAME}`)"
  - "traefik.http.routers.${STACK_NAME}-https.entrypoints=web-secure"
  - "traefik.http.routers.${STACK_NAME}-https.tls=true"
  - "traefik.http.routers.${STACK_NAME}-https.tls.certresolver=letsencrypt"
  - "traefik.http.routers.${STACK_NAME}-https.service=${STACK_NAME}"
  - "traefik.http.services.${STACK_NAME}.loadbalancer.server.port=8080"
  - "traefik.docker.network=${PROXY_NETWORK}"
```

### Use the `https-redirect@file` shortcut

Instead of defining the redirect middleware per-app, reference the
one from CS-Traefik:

```yaml
- "traefik.http.routers.${STACK_NAME}-http.rule=Host(`${SERVICE_HOSTNAME}`)"
- "traefik.http.routers.${STACK_NAME}-http.entrypoints=web"
- "traefik.http.routers.${STACK_NAME}-http.middlewares=https-redirect@file"
```

Same effect, less label-noise. Trade-off: less granular control if
you ever need a path-specific exception.

### Use the `hardened-public` chain

For maximum hardening:

```yaml
- "traefik.http.routers.${STACK_NAME}-https.middlewares=hardened-public@file"
```

That chain applies: compression + HSTS preload + frame-deny + nosniff +
referrer-strict + rate-limit.

**Don't** use this for SSE / streaming endpoints — `compression`
breaks SSE. For SSE-heavy apps, build your own chain without
compression.

## Adding the BAUER GROUP brand identity to responses

Already done. Every response from this app's router carries the fixed
brand values `Server: BAUER GROUP Edge` and `X-Powered-By: BAUER GROUP`
automatically (entrypoint-level `bg-provider` middleware) — which also
masks the real backend from fingerprinting. Caveat: Traefik's built-in
404 for unmatched hosts is emitted before the entrypoint chain and does
not carry the headers.

To verify:

```bash
curl -I https://app.bauer-group.com | grep -iE "server|x-powered-by"
# Server: BAUER GROUP Edge
# X-Powered-By: BAUER GROUP
```

## Inspecting the route

In the Traefik dashboard (`http://127.0.0.1:9090/dashboard/`):

- **HTTP** → Routers → `myapp-http@docker` (the redirect router)
- **HTTP** → Routers → `myapp-https@docker` (the HTTPS router)
- **HTTP** → Services → `myapp@docker` (the backend service)
- **HTTP** → Middlewares → `myapp-https-redirect@docker` (custom),
  `hsts-mild@file`, `nosniff@file`, `bg-provider@file`
