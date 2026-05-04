# Example: Wildcard Certificate via Cloudflare DNS-01

How to provision `*.bauer-group.com` (or any wildcard) via DNS-01
challenge using Cloudflare. The pattern works the same for any
DNS provider — see [`tls-and-certificates.md`](../tls-and-certificates.md)
for the full provider list.

## Why wildcards

- One cert covers `*.bauer-group.com` — no per-subdomain ACME calls,
  no rate-limit pressure.
- Subdomains can be created/destroyed without re-provisioning certs.
- Required for virtual-hosted-style S3 (`bucket.s3.bauer-group.com`).

DNS-01 is the **only** Let's Encrypt challenge type that supports
wildcards. HTTP-01 and TLS-ALPN-01 can't issue `*.example.com`.

## Prerequisites

1. The domain must be on Cloudflare (any plan, including Free).
2. A Cloudflare API token with **Zone DNS Edit** scope on the zone.
3. CS-Traefik already running.

## Generate the API token

In Cloudflare Dashboard → My Profile → API Tokens → Create Token:

- Use template **Edit zone DNS**.
- Zone Resources → Include → Specific zone → `bauer-group.com`.
- TTL: leave open (no expiry) or pick one.
- Save → copy the generated token. You'll see it once; store it
  somewhere safe.

The token is scoped to **only** DNS edits on this one zone. If
exposed, the blast radius is limited to creating/deleting DNS records
on that zone — much better than legacy Global API Key (full
account access).

## Configure CS-Traefik

In `/opt/edgeproxy/.env`:

```env
LETSENCRYPT_EMAIL=admin@bauer-group.com
LETSENCRYPT_DNS_PROVIDER=cloudflare
CF_DNS_API_TOKEN=...your-token-from-Cloudflare...
```

Restart so Traefik picks up the new env:

```bash
sudo /opt/edgeproxy/traefik.sh restart
```

(`traefik.sh restart` is enough — the env vars are read by the
container on startup.)

## Use the wildcard in an app router

Three things to add on the app router that needs the wildcard:

```yaml
labels:
  - "traefik.http.routers.${STACK_NAME}-https.tls.certresolver=letsencrypt-dns"
  - "traefik.http.routers.${STACK_NAME}-https.tls.domains[0].main=bauer-group.com"
  - "traefik.http.routers.${STACK_NAME}-https.tls.domains[0].sans=*.bauer-group.com"
```

Differences from the standard pattern:

- `certresolver=letsencrypt-dns` instead of `letsencrypt`.
- `tls.domains[0].main=bauer-group.com` — the bare domain.
- `tls.domains[0].sans=*.bauer-group.com` — the wildcard SAN.

The cert covers BOTH the bare `bauer-group.com` AND any single-level
subdomain under it. **Note**: wildcards are single-level — the cert
matches `app.bauer-group.com` but **not** `staging.app.bauer-group.com`
(two levels). For multi-level wildcards you need separate cert
domains:

```yaml
- "traefik.http.routers.${STACK_NAME}-https.tls.domains[0].main=bauer-group.com"
- "traefik.http.routers.${STACK_NAME}-https.tls.domains[0].sans=*.bauer-group.com"
- "traefik.http.routers.${STACK_NAME}-https.tls.domains[1].main=staging.bauer-group.com"
- "traefik.http.routers.${STACK_NAME}-https.tls.domains[1].sans=*.staging.bauer-group.com"
```

(Two separate certs — each wildcard-single-level. Let's Encrypt
counts each as a duplicate-cert against the rate limit.)

## Full example: virtual-hosted-style S3

The use case where wildcards really shine — virtual-hosted-style S3
where each bucket gets its own subdomain:

```yaml
# documentsigning/docker-compose.yml
services:
  minio-server:
    image: quay.io/minio/minio:latest
    expose: [9000/tcp]

    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${PROXY_NETWORK:-EDGEPROXY}"

      # ── HTTP redirect ──
      - "traefik.http.middlewares.${STACK_NAME}-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.${STACK_NAME}-https-redirect.redirectscheme.permanent=true"

      - "traefik.http.routers.${STACK_NAME}-s3-http.rule=HostRegexp(`^.+\\.s3\\.bauer-group\\.com$`)"
      - "traefik.http.routers.${STACK_NAME}-s3-http.entrypoints=web"
      - "traefik.http.routers.${STACK_NAME}-s3-http.middlewares=${STACK_NAME}-https-redirect"

      # ── HTTPS with wildcard cert via DNS-01 ──
      - "traefik.http.routers.${STACK_NAME}-s3.rule=HostRegexp(`^.+\\.s3\\.bauer-group\\.com$`)"
      - "traefik.http.routers.${STACK_NAME}-s3.entrypoints=web-secure"
      - "traefik.http.routers.${STACK_NAME}-s3.tls=true"
      - "traefik.http.routers.${STACK_NAME}-s3.tls.certresolver=letsencrypt-dns"
      - "traefik.http.routers.${STACK_NAME}-s3.tls.domains[0].main=s3.bauer-group.com"
      - "traefik.http.routers.${STACK_NAME}-s3.tls.domains[0].sans=*.s3.bauer-group.com"
      - "traefik.http.routers.${STACK_NAME}-s3.service=${STACK_NAME}-s3"
      - "traefik.http.routers.${STACK_NAME}-s3.middlewares=s3-streaming@file"

      - "traefik.http.services.${STACK_NAME}-s3.loadbalancer.server.port=9000"

    networks:
      - proxy
```

Result:

- `https://documents.s3.bauer-group.com` → MinIO (bucket "documents")
- `https://backups.s3.bauer-group.com` → MinIO (bucket "backups")
- `https://photos.s3.bauer-group.com` → MinIO (bucket "photos")

All same cert, all same Traefik service, MinIO routes the bucket
based on the host header.

## Verifying the cert

```bash
# Watch the ACME log during issuance
sudo /opt/edgeproxy/traefik.sh logs traefik | grep -i acme

# Inspect the issued cert
sudo cat /opt/edgeproxy/traefik/letsencrypt/letsencrypt-dns.json | jq '.letsencrypt-dns.Certificates[]'

# From the outside, check the cert is wildcard
echo | openssl s_client -showcerts -servername documents.s3.bauer-group.com -connect documents.s3.bauer-group.com:443 2>&1 | grep -A1 "Subject Alternative Name"
# DNS:s3.bauer-group.com, DNS:*.s3.bauer-group.com
```

## Common issues

### Issuance fails: "no DNS-01 challenge config"

```
error: providerName is required
```

`LETSENCRYPT_DNS_PROVIDER` isn't set, or didn't propagate to the
container. Check:

```bash
docker exec edgeproxy-traefik env | grep -E "LETSENCRYPT|CF_"
```

If not present, you forgot to restart after editing `.env`:

```bash
sudo /opt/edgeproxy/traefik.sh restart
```

### Issuance fails: "Cloudflare API: invalid token"

The `CF_DNS_API_TOKEN` is wrong, expired, or has insufficient scope.
Re-create with **Zone DNS Edit** on the specific zone and update
`.env`.

### Issuance times out / "TXT record not found"

Cloudflare's DNS propagation is fast, but the default
`delayBeforeCheck=10s` might still be too short on some edge cases.
Bump in [`config/traefik/traefik.yml`](../../config/traefik/traefik.yml):

```yaml
letsencrypt-dns:
  acme:
    dnsChallenge:
      provider: "${LETSENCRYPT_DNS_PROVIDER:-cloudflare}"
      resolvers:
        - "1.1.1.1:53"
        - "8.8.8.8:53"
      delayBeforeCheck: 30s     # was 10s
```

Then `sudo ./traefik.sh restart`.

### Rate-limit hit

Let's Encrypt production: 5 duplicate certs per week, 50 certs per
account per week. If you hit this during testing, switch the resolver
to staging:

```yaml
- "traefik.http.routers.${STACK_NAME}-https.tls.certresolver=letsencrypt-staging"
```

But there's no `letsencrypt-staging-dns` for DNS-01. To use staging
for a DNS-01 cert during testing, override the CA endpoint via
`.env`:

```env
LETSENCRYPT_CA=https://acme-staging-v02.api.letsencrypt.org/directory
```

(This affects ALL resolvers temporarily. Switch back to production
after testing.)

## Cleanup if you stop using wildcards

If you switch from wildcard to per-subdomain certs and want to clean
up:

```bash
sudo /opt/edgeproxy/traefik.sh stop

# Remove the DNS-01 ACME storage file
sudo rm /opt/edgeproxy/traefik/letsencrypt/letsencrypt-dns.json

# Optionally clear Cloudflare credentials from .env
# (won't break anything if they stay -- just unused)

sudo /opt/edgeproxy/traefik.sh start
```

The next router that uses `letsencrypt` (HTTP-01) will issue a fresh
non-wildcard cert.
