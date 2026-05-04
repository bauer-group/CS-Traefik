# TLS & Certificates

How CS-Traefik manages TLS for app routes — Let's Encrypt automation,
manual / corporate-CA certificates, mTLS, and TLS-options profiles.

## TL;DR

Apps select a cert resolver per router via labels:

```yaml
labels:
  - "traefik.http.routers.myapp.tls=true"
  - "traefik.http.routers.myapp.tls.certresolver=letsencrypt"
```

Four resolvers are pre-wired:

| Resolver | Challenge | When |
| --- | --- | --- |
| `letsencrypt` | HTTP-01 (port 80) | DEFAULT. RFC 8555 MUST-implement. Universal. |
| `letsencrypt-tls` | TLS-ALPN-01 (port 443) | Fallback when port 80 is fronted. |
| `letsencrypt-dns` | DNS-01 | Wildcards / firewalled hosts. Provider via `LETSENCRYPT_DNS_PROVIDER` in `.env`. |
| `letsencrypt-staging` | HTTP-01 (staging) | Initial roll-out. No rate-limit pain. |

Plus manual / BYO certificates via
[`config/traefik/dynamic/tls.yml`](../config/traefik/dynamic/tls.yml).

## Why HTTP-01 first?

Priority order: **HTTP-01 → TLS-ALPN-01 → DNS-01**.

- **HTTP-01** is RFC 8555 MUST-implement — universal compatibility.
- Works through CDNs / WAFs that pass HTTP through but might not
  expose the underlying TLS handshake to the upstream.
- Lowest setup friction — no TLS state machine, just a URL fetch.

**TLS-ALPN-01** is the fallback when port 80 is unreachable / hijacked
/ fronted by an upstream proxy that terminates HTTP. Reuses the 443
listener so no new ports are needed.

**DNS-01** is last because it's slowest (DNS propagation + checks).
Use only when needed — wildcards (`*.bauer-group.com`) or hosts that
aren't reachable from the public internet.

## Let's Encrypt

### Prerequisites

- `LETSENCRYPT_EMAIL` set in `.env` (registration + expiry mail).
- DNS A/AAAA records for your hostnames pointing at the Traefik host.
- Port 80 reachable from the public internet (HTTP-01) **or** port 443
  reachable (TLS-ALPN-01) **or** DNS-provider API credentials (DNS-01).
- ACME storage directory writable: `${DATA_DIRECTORY}/traefik/letsencrypt/`
  (created automatically by `traefik.sh start`, chmod 700).

### Use staging during initial roll-out

Production Let's Encrypt has rate limits:

- 5 duplicate certs per week per registered domain.
- 50 certs per account per week.
- 300 new orders per account per 3 hours.

Hit these limits during testing and you're locked out for a week.

Switch a router to staging via labels:

```yaml
- "traefik.http.routers.myapp.tls.certresolver=letsencrypt-staging"
```

Or globally via env (affects all routers using `letsencrypt`):

```env
LETSENCRYPT_CA=https://acme-staging-v02.api.letsencrypt.org/directory
```

When everything works, swap back to production. Old staging certs are
discarded automatically; production certs are issued on first request.

### Switching challenge type per router

Most apps just use `letsencrypt` (HTTP-01). To use TLS-ALPN-01 for a
specific router (e.g. when port 80 is fronted by a CDN that hides
HTTP):

```yaml
- "traefik.http.routers.myapp.tls.certresolver=letsencrypt-tls"
```

For DNS-01 (wildcards), see [Wildcards](#wildcards-dns-01) below.

## Wildcards (DNS-01)

Wildcard certs (`*.bauer-group.com`) require DNS-01. The
`letsencrypt-dns` resolver is **active and parameterised** — pick a
provider in `.env`:

```env
LETSENCRYPT_DNS_PROVIDER=cloudflare
CF_DNS_API_TOKEN=...
```

Then on the app router:

```yaml
labels:
  - "traefik.http.routers.myapp.tls=true"
  - "traefik.http.routers.myapp.tls.certresolver=letsencrypt-dns"
  - "traefik.http.routers.myapp.tls.domains[0].main=bauer-group.com"
  - "traefik.http.routers.myapp.tls.domains[0].sans=*.bauer-group.com"
```

The cert covers both the bare `bauer-group.com` and any subdomain
under it.

### Pre-wired DNS providers

24 providers have credentials wired through `docker-compose.yml`. You
only need to populate the env vars for **your** chosen provider.

**International:**

| Provider | Key | Required env vars |
| --- | --- | --- |
| Cloudflare | `cloudflare` | `CF_DNS_API_TOKEN` (recommended) or `CF_API_EMAIL` + `CF_API_KEY` |
| AWS Route 53 | `route53` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` |
| Google Cloud DNS | `gcloud` | `GCE_PROJECT`, `GCE_SERVICE_ACCOUNT_FILE` |
| Azure DNS | `azuredns` | `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP` |
| DigitalOcean | `digitalocean` | `DO_AUTH_TOKEN` |
| Linode | `linode` | `LINODE_TOKEN` |
| Vultr | `vultr` | `VULTR_API_KEY` |
| OVH | `ovh` | `OVH_ENDPOINT`, `OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY` |
| Gandi v5 | `gandiv5` | `GANDIV5_PERSONAL_ACCESS_TOKEN` |
| DNSimple | `dnsimple` | `DNSIMPLE_OAUTH_TOKEN` |
| Namecheap | `namecheap` | `NAMECHEAP_API_USER`, `NAMECHEAP_API_KEY` |
| GoDaddy | `godaddy` | `GODADDY_API_KEY`, `GODADDY_API_SECRET` |
| Scaleway | `scaleway` | `SCW_ACCESS_KEY`, `SCW_SECRET_KEY`, `SCW_PROJECT_ID` |
| DuckDNS | `duckdns` | `DUCKDNS_TOKEN` |

**DACH-focused:**

| Provider | Key | Required env vars |
| --- | --- | --- |
| Hetzner | `hetzner` | `HETZNER_API_KEY` |
| IONOS / 1&1 | `ionos` | `IONOS_API_KEY` (`public.secret` format) |
| Netcup | `netcup` | `NETCUP_CUSTOMER_NUMBER`, `NETCUP_API_KEY`, `NETCUP_API_PASSWORD` |
| INWX | `inwx` | `INWX_USERNAME`, `INWX_PASSWORD`, optionally `INWX_SHARED_SECRET` (2FA TOTP) |
| Hosting.de | `hostingde` | `HOSTINGDE_API_KEY`, `HOSTINGDE_ZONE_NAME` |

**APAC:**

| Provider | Key | Required env vars |
| --- | --- | --- |
| DNSPod | `dnspod` | `DNSPOD_API_KEY` |
| Tencent Cloud DNS | `tencentcloud` | `TENCENTCLOUD_SECRET_ID`, `TENCENTCLOUD_SECRET_KEY` |

**Self-hosted / custom:**

| Provider | Key | Required env vars |
| --- | --- | --- |
| Designate (OpenStack) | `designate` | `OS_AUTH_URL`, `OS_USERNAME`, `OS_PASSWORD`, `OS_TENANT_NAME`, `OS_REGION_NAME` |
| ACME-DNS (alias) | `acme-dns` | `ACME_DNS_API_BASE`, `ACME_DNS_STORAGE_PATH` |
| RFC 2136 (BIND) | `rfc2136` | `RFC2136_NAMESERVER`, `RFC2136_TSIG_ALGORITHM`, `RFC2136_TSIG_KEY`, `RFC2136_TSIG_SECRET` |
| Generic exec | `exec` | `EXEC_PATH`, `EXEC_MODE` |

For providers not in this list, see [Traefik's full provider
list](https://doc.traefik.io/traefik/https/acme/#providers) (100+
options). Just add the provider's env vars to `.env` — Compose passes
them through to the container automatically. Update
[`docker-compose.yml`](../docker-compose.yml) to make the wiring
explicit (recommended).

## Manual / corporate-CA certificates

Drop `*.crt` + `*.key` files into [`config/certs/static/`](../config/certs/static/),
then list each pair in
[`config/traefik/dynamic/tls.yml`](../config/traefik/dynamic/tls.yml):

```yaml
tls:
  certificates:
    - certFile: /etc/traefik/certs/static/customer.example.com.crt
      keyFile:  /etc/traefik/certs/static/customer.example.com.key
      stores:
        - default
```

Use cases:

- Wildcard certs from a corporate / private CA.
- EV / OV certs purchased from a commercial CA.
- Internal-only domains where Let's Encrypt doesn't apply.

Traefik picks the right cert per host based on the SNI in the TLS
handshake (matches the cert's SAN / CN). Apps reference the resolver
as usual; the manual cert wins for matching SNIs, others fall through
to Let's Encrypt.

The `static/` directory is mounted read-only into Traefik and watched
for changes — drop a new cert and Traefik picks it up live.

The directory is `.gitignore`d for `*.crt`, `*.key`, `*.pem`, `*.p12`,
`*.pfx` — private keys never reach the repo.

### `*.bauer-group.com` wildcard (opt-in template)

For the BG corporate wildcard specifically, a ready-to-activate
template ships in
[`config/traefik/dynamic/tls-wildcard-bauer-group.yml.disabled`](../config/traefik/dynamic/tls-wildcard-bauer-group.yml.disabled).
The `.disabled` suffix keeps it inactive until an operator wires
it up explicitly.

**Activate:**

**Step 1 — drop the cert + key into `config/certs/static/`** with the
canonical names the template expects:

```text
config/certs/static/bauer-group.pem    # PEM-encoded full chain
config/certs/static/bauer-group.key    # PEM-encoded private key (unencrypted)
```

**Step 2 — rename the template** (drops the `.disabled` suffix):

```bash
mv config/traefik/dynamic/tls-wildcard-bauer-group.yml.disabled \
   config/traefik/dynamic/tls-wildcard-bauer-group.yml
```

Traefik reloads automatically (file provider has `watch: true`) — no
restart needed.

**Step 3 — verify** in the dashboard under **HTTP → TLS → Certificates**
that `*.bauer-group.com` appears in the SAN list.

Once active, Traefik serves the wildcard for any SNI matching
`*.bauer-group.com` (e.g. `api.bauer-group.com`, `app.bauer-group.com`,
`www.bauer-group.com`). Routers for those hosts do NOT need to set
`tls.certresolver` — the wildcard handles the handshake. Setting an
ACME resolver on a host already covered by the wildcard burns Let's
Encrypt rate-limit budget on a redundant cert.

**Renewal:** corporate-CA certs are rotated manually. Drop in the
new `.pem` / `.key` pair and Traefik reloads them live. Verify
expiry from the host:

```bash
openssl x509 -enddate -noout -in config/certs/static/bauer-group.pem
```

**Deactivate:** rename back to `.yml.disabled` (or delete the `.yml`).
Routers fall back to ACME / their declared `certresolver` on next
reload.

## TLS options (cipher suites, min version)

Defined in [`config/traefik/dynamic/tls.yml`](../config/traefik/dynamic/tls.yml).
Three pre-configured option sets, plus an mTLS template:

| Option set | Min TLS | Cipher list | When |
| --- | --- | --- | --- |
| `default` | TLS 1.1 | Wide (TLS 1.3 + AEAD + legacy CBC + RSA-KEX) | Public web apps with global / mobile / emerging-market audience. Matches legacy v2 stack. |
| `intermediate` | TLS 1.2 | Modern AEAD only | Mozilla "Intermediate" recipe — modern browsers and iOS 11+ / Android 5+. |
| `modern` | TLS 1.3 | TLS 1.3 only | Admin surfaces, payment flows, PCI-DSS workloads. No legacy clients. |
| `mtls` | TLS 1.2 | (commented template) | Backend-only routers with client certificate authentication. |

Apps select an option set per router:

```yaml
- "traefik.http.routers.myapp.tls.options=modern@file"
```

Without an explicit selection, the `default` block applies (permissive
by design — see below for the rationale).

### Why TLS 1.1 minimum (not 1.2 or 1.3)?

BAUER GROUP serves users in regions where legacy browsers and feature
phones (Android <5, KaiOS, older WebViews) are still common. TLS 1.1
keeps these users online while TLS 1.0 stays disabled (POODLE / BEAST
/ SWEET32 mitigations are too poor at that level).

For sensitive routes (admin / payment / PCI), opt into stricter via
`tls.options=modern@file` (TLS 1.3 only) or
`tls.options=intermediate@file` (TLS 1.2 + AEAD only).

### Cipher list (the `default` profile)

Includes:

- TLS 1.3 ciphers (auto-negotiated, not listed).
- TLS 1.2 modern AEAD: `TLS_ECDHE_*_AES_*_GCM_*` and
  `TLS_ECDHE_*_CHACHA20_POLY1305`.
- TLS 1.2 legacy CBC: required by older Android, iOS 9, IE on Win7.
- TLS 1.2 RSA key-exchange (no PFS): last-resort for very old
  clients. Drop these in production if compliance requires PFS-only.

Curve preferences: `X25519`, `secp521r1`, `secp384r1`, `secp256r1`.

ALPN: `h2` + `http/1.1`.

## mTLS (client-certificate authentication)

Template in `tls.yml`:

```yaml
tls:
  options:
    mtls:
      minVersion: VersionTLS12
      clientAuth:
        caFiles:
          - /etc/traefik/certs/static/ca.pem
        clientAuthType: RequireAndVerifyClientCert
```

Drop your CA bundle into `config/certs/static/ca.pem`, uncomment the
block, and reference per-router:

```yaml
- "traefik.http.routers.backend.tls.options=mtls@file"
```

Only clients holding a certificate signed by your CA can reach the
router. Useful for service-to-service auth, internal admin endpoints,
or B2B partner integrations.

## Default certificate (TLS handshake fallback)

By default Traefik returns its built-in `TRAEFIK DEFAULT CERT` to
clients that connect with an unknown SNI (or no SNI at all — common
from misconfigured probes / port scanners). This scares any TLS
scanner.

To provide a self-signed bind cert instead, uncomment in
[`config/traefik/dynamic/tls.yml`](../config/traefik/dynamic/tls.yml):

```yaml
stores:
  default:
    defaultCertificate:
      certFile: /etc/traefik/certs/static/default.crt
      keyFile:  /etc/traefik/certs/static/default.key
```

## Inspecting issued certificates

The ACME storage file:

```bash
sudo cat ${DATA_DIRECTORY}/traefik/letsencrypt/letsencrypt.json | jq .
```

Shows:

- Account registration (private key, contact email).
- Each issued certificate (PEM-encoded, expiry, domains, challenge
  type).
- Last renewal attempt timestamps.

ACME storage files MUST be `chmod 600` or Traefik refuses to use
them. `traefik.sh start` enforces this on every restart.

## Renewals

Traefik renews certificates 30 days before expiry, automatically. No
operator action required — assuming the challenge type still works
(port 80 / 443 reachable / DNS provider creds still valid).

Renewals show up in the Traefik logs:

```
sudo ./traefik.sh logs traefik | grep -i acme
```

The Prometheus alert rule `TraefikCertExpiringSoon` fires if any cert
has less than 14 days to expiry — by then the auto-renewal should have
already fired at 30 days, so a firing alert means the renewal failed
and you should check the ACME log.

## Common failure modes

See [`operations/troubleshooting.md`](operations/troubleshooting.md)
for ACME-specific debugging.

Quick sanity checks:

- Port 80 reachable from the public internet?
  ```bash
  curl -I http://your.domain.tld/.well-known/acme-challenge/test
  ```
- DNS A/AAAA correct?
  ```bash
  dig +short your.domain.tld
  ```
- Rate limit hit?
  ```bash
  sudo ./traefik.sh logs traefik | grep -i "rate limit"
  ```
- DNS-01 propagation slow?
  Increase `delayBeforeCheck` in
  [`config/traefik/traefik.yml`](../config/traefik/traefik.yml) (default
  is 10s, raise to 30s-60s for slow providers).
