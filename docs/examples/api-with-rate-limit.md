# Example: API with Rate Limit + CORS + Body Cap

A REST API behind CS-Traefik with body-size enforcement, rate-limit,
CORS, and retry-on-transient-failures.

## Compose

```yaml
# api/docker-compose.yml
name: ${STACK_NAME:-api}

services:

  api:
    image: ghcr.io/bauer-group/my-api:latest
    container_name: ${STACK_NAME:-api}-server
    restart: unless-stopped

    environment:
      - DATABASE_URL=postgresql://api:${DATABASE_PASSWORD}@db:5432/api
      - REDIS_URL=redis://redis:6379

    expose:
      - 3000/tcp

    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:3000/health"]
      interval: 30s
      timeout: 5s
      retries: 3

    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${PROXY_NETWORK:-EDGEPROXY}"

      # ── HTTP redirect ──
      - "traefik.http.middlewares.${STACK_NAME:-api}-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.${STACK_NAME:-api}-https-redirect.redirectscheme.permanent=true"

      - "traefik.http.routers.${STACK_NAME:-api}-http.rule=Host(`${API_HOSTNAME}`)"
      - "traefik.http.routers.${STACK_NAME:-api}-http.entrypoints=web"
      - "traefik.http.routers.${STACK_NAME:-api}-http.middlewares=${STACK_NAME:-api}-https-redirect"

      # ── HTTPS router ──
      - "traefik.http.routers.${STACK_NAME:-api}-https.rule=Host(`${API_HOSTNAME}`)"
      - "traefik.http.routers.${STACK_NAME:-api}-https.entrypoints=web-secure"
      - "traefik.http.routers.${STACK_NAME:-api}-https.tls=true"
      - "traefik.http.routers.${STACK_NAME:-api}-https.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${STACK_NAME:-api}-https.service=${STACK_NAME:-api}"

      # ── Per-app CORS middleware (specific origins, credentials-bearing) ──
      - "traefik.http.middlewares.${STACK_NAME:-api}-cors.headers.accessControlAllowOriginList=https://app.bauer-group.com,https://admin.bauer-group.com"
      - "traefik.http.middlewares.${STACK_NAME:-api}-cors.headers.accessControlAllowMethods=GET,POST,PUT,DELETE,PATCH,OPTIONS"
      - "traefik.http.middlewares.${STACK_NAME:-api}-cors.headers.accessControlAllowHeaders=Authorization,Content-Type,X-Requested-With"
      - "traefik.http.middlewares.${STACK_NAME:-api}-cors.headers.accessControlAllowCredentials=true"
      - "traefik.http.middlewares.${STACK_NAME:-api}-cors.headers.accessControlMaxAge=3600"
      - "traefik.http.middlewares.${STACK_NAME:-api}-cors.headers.addVaryHeader=true"

      # ── Middleware chain ──
      # Order matters: CORS first (to set headers + handle preflight),
      # then rate-limit (to bound traffic), then body-limit (cap size),
      # then retry (transient failures), then security headers.
      - "traefik.http.routers.${STACK_NAME:-api}-https.middlewares=${STACK_NAME:-api}-cors,rate-limit@file,body-limit-10mb@file,retry@file,hardened-api@file"

      - "traefik.http.services.${STACK_NAME:-api}.loadbalancer.server.port=3000"

    networks:
      - proxy
      - internal

  db:
    image: postgres:18-alpine
    expose: [5432/tcp]
    environment:
      - POSTGRES_DB=api
      - POSTGRES_USER=api
      - POSTGRES_PASSWORD=${DATABASE_PASSWORD}
    volumes:
      - db-data:/var/lib/postgresql/data
    networks:
      - internal

  redis:
    image: redis:8-alpine
    expose: [6379/tcp]
    networks:
      - internal

volumes:
  db-data:

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-EDGEPROXY}
  internal:
    driver: bridge
```

## .env

```env
STACK_NAME=customer-api
API_HOSTNAME=api.bauer-group.com
PROXY_NETWORK=EDGEPROXY

DATABASE_PASSWORD=...generate...
```

## What each middleware contributes

| Middleware | What it adds |
| --- | --- |
| `${STACK_NAME}-cors` | Allow only `app.bauer-group.com` + `admin.bauer-group.com` to make credentials-bearing CORS requests. |
| `rate-limit@file` | 5000 req/s avg / 10000 burst per IP (CGNAT-tolerant baseline). |
| `body-limit-10mb@file` | Reject requests > 10 MB. Useful guard against accidentally-huge JSON imports. |
| `retry@file` | Retry idempotent requests (GET / HEAD / OPTIONS / PUT / DELETE) up to 3 times on transient backend failures. |
| `hardened-api@file` | HSTS (mild) + nosniff + server-scrub + rate-limit (overrides the previous one) + body-limit (overrides). Convenience chain. |

Note `hardened-api@file` already includes `rate-limit + body-limit-10mb`,
so applying both `rate-limit@file,body-limit-10mb@file` AND
`hardened-api@file` is redundant — pick one approach. Either:

```yaml
# Option A: explicit middlewares
- "traefik.http.routers.X.middlewares=${STACK_NAME}-cors,rate-limit@file,body-limit-10mb@file,retry@file"
```

or

```yaml
# Option B: pre-composed chain + extras
- "traefik.http.routers.X.middlewares=${STACK_NAME}-cors,retry@file,hardened-api@file"
```

The `.env` example above used the chain (Option B is shorter).

## Variants

### Public read-only API (no credentials)

For an API that doesn't carry cookies / auth and serves any caller
(documentation API, status API, public analytics):

```yaml
- "traefik.http.routers.${STACK_NAME}-https.middlewares=cors-permissive@file,rate-limit@file,hardened-api@file"
```

`cors-permissive@file` allows `*` origin (no credentials).

### High-traffic API (CGNAT users)

If the API serves mobile clients in CGNAT-heavy regions, swap
`rate-limit` for `rate-limit-permissive`:

```yaml
- "traefik.http.routers.${STACK_NAME}-https.middlewares=${STACK_NAME}-cors,rate-limit-permissive@file,body-limit-10mb@file,retry@file"
```

20 000 req/s instead of 5 000.

### API with body-size > 10 MB allowed

```yaml
- "traefik.http.routers.${STACK_NAME}-https.middlewares=${STACK_NAME}-cors,rate-limit@file,body-limit-100mb@file,retry@file"
```

100 MB is generous but still bounded. For unbounded (file uploads,
S3-style endpoints) — don't apply any body-limit middleware (just
streaming, see [`minio-s3.md`](minio-s3.md)).

### API with circuit-breaker

If the backend is occasionally flaky and you want fail-fast instead
of cascading errors:

```yaml
- "traefik.http.routers.${STACK_NAME}-https.middlewares=${STACK_NAME}-cors,rate-limit@file,body-limit-10mb@file,circuit-breaker@file,retry@file"
```

`circuit-breaker@file` trips at 30 % 5xx errors over 10s — once
tripped, returns 503 immediately for 10s, then half-opens to test.
`retry@file` is in front of it so transient failures get retried
before counting toward the breaker threshold.

## Verifying

### CORS preflight

```bash
curl -X OPTIONS https://api.bauer-group.com/v1/users \
  -H "Origin: https://app.bauer-group.com" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: Authorization,Content-Type" \
  -v
```

Should return 204 with:

```
Access-Control-Allow-Origin: https://app.bauer-group.com
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, PATCH, OPTIONS
Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With
Access-Control-Allow-Credentials: true
Access-Control-Max-Age: 3600
Vary: Origin
```

A request from a non-allowed origin gets the same 204 but **no**
`Access-Control-Allow-Origin` header → browser blocks the actual
request.

### Rate-limit

Hammer with 100 parallel requests:

```bash
for i in {1..100}; do
  curl -s -o /dev/null -w "%{http_code}\n" \
    https://api.bauer-group.com/health &
done | sort | uniq -c
```

You should see ~100 of `200`. With `rate-limit@file` (5000 req/s
average), 100 concurrent requests are well under the threshold.

To trigger a 429: ramp to 50 000 over a single second (impractical
without specialized load tools).

### Body cap

```bash
# 9 MB body -- accepted
dd if=/dev/zero bs=1M count=9 | curl -X POST \
  -H "Authorization: Bearer ..." \
  --data-binary @- \
  https://api.bauer-group.com/v1/upload
# → 200 OK

# 11 MB body -- rejected
dd if=/dev/zero bs=1M count=11 | curl -X POST \
  -H "Authorization: Bearer ..." \
  --data-binary @- \
  https://api.bauer-group.com/v1/upload
# → 413 Request Entity Too Large
```

## Inspecting in the dashboard

The Traefik dashboard at `http://127.0.0.1:9090/dashboard/`:

- **HTTP** → Routers → `customer-api-https@docker`
- **HTTP** → Middlewares → `customer-api-cors@docker` (custom CORS),
  plus `rate-limit@file`, `body-limit-10mb@file`, `retry@file`,
  `hardened-api@file`, `bg-provider@file` (entrypoint-level)
- **HTTP** → Services → `customer-api@docker` → server `3000`
