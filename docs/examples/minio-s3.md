# Example: MinIO / S3 behind Traefik

The pattern for putting MinIO (or any S3-compatible object store)
behind CS-Traefik. Drop-in compatible with the legacy v2 stack —
your existing DocumentSigning compose works as-is.

## What you need

- Streaming pass-through (multi-GB uploads / downloads) — **default**.
- No body-size limit — **default**.
- No request/response timeouts on the wire — **default** (fixed in
  the v0.1.3 release of this stack).
- Let's Encrypt cert for the S3 hostname — **just label-driven**.

The good news: out of the box, CS-Traefik already does all of this
correctly. No special middleware, no buffering tweak, no timeout
override needed at the app level.

## Compose

```yaml
# documentsigning/docker-compose.traefik.yml
name: ${STACK_NAME}

services:

  minio-server:
    image: quay.io/minio/minio:latest
    container_name: ${STACK_NAME}_MINIO
    restart: unless-stopped

    command: server --address ":9000" --console-address ":9001" /data

    environment:
      - MINIO_ROOT_USER=${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
      - MINIO_REGION_NAME=${MINIO_REGION:-global}
      # Disable built-in browser if you use a separate console container;
      # leave on if MinIO's browser is your admin UI.
      - MINIO_BROWSER=off

    expose:
      - 9000/tcp

    volumes:
      - minio-data:/data

    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 5s
      retries: 4
      start_period: 15s

    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${PROXY_NETWORK:-EDGEPROXY}"

      # ── HTTP redirect to HTTPS ─────────────────────────────────────
      - "traefik.http.middlewares.${STACK_NAME}-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.${STACK_NAME}-https-redirect.redirectscheme.permanent=true"

      - "traefik.http.routers.${STACK_NAME}-s3-http.rule=Host(`${S3_HOSTNAME}`)"
      - "traefik.http.routers.${STACK_NAME}-s3-http.entrypoints=web"
      - "traefik.http.routers.${STACK_NAME}-s3-http.middlewares=${STACK_NAME}-https-redirect"

      # ── S3 API on HTTPS (path-style: https://s3.example.com/bucket/key) ──
      - "traefik.http.routers.${STACK_NAME}-s3.rule=Host(`${S3_HOSTNAME}`)"
      - "traefik.http.routers.${STACK_NAME}-s3.entrypoints=web-secure"
      - "traefik.http.routers.${STACK_NAME}-s3.tls=true"
      - "traefik.http.routers.${STACK_NAME}-s3.tls.certresolver=letsencrypt"
      - "traefik.http.routers.${STACK_NAME}-s3.service=${STACK_NAME}-s3"

      # Use the s3-streaming chain:
      #   - rate-limit-permissive  (multipart with high concurrency)
      #   - server-scrub           (strip upstream Server header)
      # Notably ABSENT: any buffering / body-limit / compression
      # middleware. S3 needs streaming, not buffering.
      - "traefik.http.routers.${STACK_NAME}-s3.middlewares=s3-streaming@file"

      - "traefik.http.services.${STACK_NAME}-s3.loadbalancer.server.port=9000"

    networks:
      - proxy

volumes:
  minio-data:
    name: ${STACK_NAME}-minio

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-EDGEPROXY}
```

## .env

```env
STACK_NAME=signing
S3_HOSTNAME=s3.bauer-group.com
PROXY_NETWORK=EDGEPROXY

MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=...generate...
MINIO_REGION=eu-central-1
```

## Verify multipart upload works end-to-end

From a client:

```bash
# Install awscli (or use mc, the MinIO client)
pip install awscli

# Configure
aws configure --profile minio
# Access Key: <S3_ACCESS_KEY from your provisioning>
# Secret Key: <S3_SECRET_KEY>
# Region: eu-central-1
# Output: json

# Multipart upload of a 1 GB file
aws --profile minio --endpoint-url https://s3.bauer-group.com \
    s3 cp ./large-file-1gb.bin s3://documents/test/large-file.bin
```

Behind the scenes:

1. AWS CLI splits the file into 8 MB parts (default).
2. For each part, opens an HTTPS connection to
   `https://s3.bauer-group.com/documents/test/large-file.bin?partNumber=N&uploadId=...`.
3. Streams the part body via PUT.
4. Once all parts complete, sends the multipart-complete request.

CS-Traefik:

- TLS-terminates each connection.
- Streams the request body to MinIO without buffering.
- No `readTimeout` (the upload can take hours on slow links).
- No `writeTimeout` (the upload-complete confirmation can take a
  while if MinIO is doing internal copy on completion).
- Returns the upstream response back to the client.

This works because:

| Concern | What CS-Traefik does |
| --- | --- |
| Body size unlimited | Default — no buffering middleware applied. |
| Request streaming | Default — Traefik doesn't buffer unless the buffering middleware is applied. |
| `readTimeout=0s` | Set explicitly in `traefik.yml` (legacy v2 compat). |
| `writeTimeout=0s` | Set explicitly in `traefik.yml`. |
| Header pass-through (`Authorization`, `x-amz-*`) | Default — Traefik forwards all headers transparently. |
| Source IP rate-limit | `rate-limit-permissive` (20k req/s) accommodates parallel multipart parts. |

## What NOT to do

### Don't apply a `buffering` middleware

The legacy DocumentSigning compose has:

```yaml
- "traefik.http.middlewares.${STACK_NAME}-nobuffer.buffering.maxRequestBodyBytes=0"
- "traefik.http.middlewares.${STACK_NAME}-nobuffer.buffering.memRequestBodyBytes=0"
- "traefik.http.middlewares.${STACK_NAME}-nobuffer.buffering.maxResponseBodyBytes=0"
- "traefik.http.middlewares.${STACK_NAME}-nobuffer.buffering.memResponseBodyBytes=0"
```

This is **counter-productive**. The Traefik buffering middleware,
when applied with all values set to 0, doesn't disable buffering —
it sets `memRequestBodyBytes=0` (zero memory buffer), which forces
the entire body to disk-spill before forwarding. For multi-GB uploads
that's extra latency and disk usage you don't need.

The right pattern is to **not** apply any buffering middleware. Then
Traefik streams directly from client to backend without touching the
body.

### Don't apply `body-limit-*` middleware

The `body-limit-1mb` / `body-limit-10mb` / `body-limit-100mb`
middlewares enforce a hard cap. For S3 endpoints they would reject
any upload over the cap. Don't apply them on S3 routes.

### Don't apply `compression` middleware

S3 responses are already type-encoded (binary objects, often
already-compressed). Compressing them again wastes CPU and may break
clients that expect specific Content-Length.

### Don't apply `rate-limit-strict`

That's 10 req/s — a single multipart upload of 100 parts at once
would 503 immediately. Use `rate-limit-permissive` (20k req/s) or
just `rate-limit` (5k req/s).

## Variants

### Virtual-hosted-style (`https://bucket.s3.example.com/key`)

Most S3 SDKs default to virtual-hosted-style, but path-style is more
common for self-hosted MinIO. To support virtual-hosted-style, you
need a wildcard cert:

```yaml
labels:
  - "traefik.http.routers.${STACK_NAME}-s3.rule=HostRegexp(`^.+\\.s3\\.bauer-group\\.com$`)"
  - "traefik.http.routers.${STACK_NAME}-s3.tls.certresolver=letsencrypt-dns"
  - "traefik.http.routers.${STACK_NAME}-s3.tls.domains[0].main=s3.bauer-group.com"
  - "traefik.http.routers.${STACK_NAME}-s3.tls.domains[0].sans=*.s3.bauer-group.com"
```

Plus DNS-01 wildcard cert config in `.env`:

```env
LETSENCRYPT_DNS_PROVIDER=cloudflare
CF_DNS_API_TOKEN=...
```

See [`wildcard-cert-cloudflare.md`](wildcard-cert-cloudflare.md) for
full details.

### Separate S3 console (admin UI)

MinIO offers a separate console container for the admin UI. Routed
on its own hostname:

```yaml
admin-console:
  image: ghcr.io/bauer-group/cs-minio/minio-console:latest
  container_name: ${STACK_NAME}_CONSOLE

  environment:
    - CONSOLE_MINIO_SERVER=http://minio-server:9000
    - CONSOLE_MINIO_REGION=${MINIO_REGION}

  expose:
    - 9090/tcp

  labels:
    - "traefik.enable=true"
    - "traefik.docker.network=${PROXY_NETWORK}"

    - "traefik.http.routers.${STACK_NAME}-console-http.rule=Host(`${S3_CONSOLE_HOSTNAME}`)"
    - "traefik.http.routers.${STACK_NAME}-console-http.entrypoints=web"
    - "traefik.http.routers.${STACK_NAME}-console-http.middlewares=${STACK_NAME}-https-redirect"

    - "traefik.http.routers.${STACK_NAME}-console.rule=Host(`${S3_CONSOLE_HOSTNAME}`)"
    - "traefik.http.routers.${STACK_NAME}-console.entrypoints=web-secure"
    - "traefik.http.routers.${STACK_NAME}-console.tls=true"
    - "traefik.http.routers.${STACK_NAME}-console.tls.certresolver=letsencrypt"
    - "traefik.http.routers.${STACK_NAME}-console.service=${STACK_NAME}-console"
    - "traefik.http.routers.${STACK_NAME}-console.middlewares=hardened-public@file"

    - "traefik.http.services.${STACK_NAME}-console.loadbalancer.server.port=9090"

  depends_on:
    minio-server:
      condition: service_healthy

  networks:
    - proxy
```

The console is a regular HTTPS web app — apply the `hardened-public`
chain (HSTS + frame-deny + nosniff + compression + rate-limit).

### Behind Cloudflare / WAF

If you front MinIO with Cloudflare, two things to know:

1. Cloudflare's **free plan** has a 100 MB upload limit. Pro is 200
   MB; Business is 500 MB; Enterprise is 5 GB. For multi-GB S3
   uploads you need to bypass Cloudflare for the S3 hostname or pay
   for an enterprise-class CDN.
2. Cloudflare's TLS edge breaks `tls.options=modern@file` if
   Cloudflare is serving with TLS 1.2 — the negotiation happens at
   Cloudflare, not Traefik.

For S3 specifically, **don't proxy through Cloudflare** unless you
have a clear reason. Direct DNS A/AAAA → Traefik works fine and
avoids the upload-size limit.
