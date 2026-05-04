# Example: Forward-Auth via Authelia

Single-sign-on across all your apps via [Authelia](https://www.authelia.com/),
delegated through Traefik's `forwardAuth` middleware.

## Why forward-auth

- One login screen for all your apps. User authenticates once, then
  every protected app trusts Authelia's session cookie.
- Two-factor authentication (TOTP / WebAuthn) without each app
  implementing it.
- Centralised access control rules (which user / group can reach
  which app).
- No code changes in the apps — auth happens at the edge.

## Architecture

```text
                                    ┌────────────────────┐
       ┌────────────────────────────▶│   Authelia         │
       │  forward-auth sub-request   │   - LDAP / file    │
       │  for every public request   │   - 2FA            │
       │                             │   - session cookie │
       │  ┌──────────────────────────┤   - access rules   │
       │  │  authResponseHeaders     └─────────▲──────────┘
       │  │  (Remote-User, Groups)             │
       ▼  ▼                                    │
   ┌──────────────┐                            │
   │  Traefik     │                            │
   │  (edge)      │ ◄── browser session cookie ┘
   └──────┬───────┘
          │  (only after Authelia returns 200)
          ▼
   ┌──────────────┐
   │  Your app    │  receives X-Forwarded-User, X-Forwarded-Groups, etc.
   └──────────────┘
```

## Compose: Authelia stack

```yaml
# authelia/docker-compose.yml
name: authelia

services:

  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    restart: unless-stopped

    expose:
      - 9091/tcp

    volumes:
      - ./config:/config
      - authelia-data:/var/lib/authelia

    environment:
      - TZ=${TIME_ZONE:-Etc/UTC}
      # JWT secret for session signing. Random 64-char hex.
      - AUTHELIA_JWT_SECRET=${AUTHELIA_JWT_SECRET}
      # Session cookie encryption.
      - AUTHELIA_SESSION_SECRET=${AUTHELIA_SESSION_SECRET}
      # Storage encryption (for stored TOTP secrets).
      - AUTHELIA_STORAGE_ENCRYPTION_KEY=${AUTHELIA_STORAGE_ENCRYPTION_KEY}

    healthcheck:
      test: ["CMD", "authelia", "healthcheck"]
      interval: 30s

    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=${PROXY_NETWORK:-EDGEPROXY}"

      # Authelia's own UI (login page) on https://auth.bauer-group.com
      - "traefik.http.middlewares.authelia-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.authelia-https-redirect.redirectscheme.permanent=true"

      - "traefik.http.routers.authelia-http.rule=Host(`auth.bauer-group.com`)"
      - "traefik.http.routers.authelia-http.entrypoints=web"
      - "traefik.http.routers.authelia-http.middlewares=authelia-https-redirect"

      - "traefik.http.routers.authelia-https.rule=Host(`auth.bauer-group.com`)"
      - "traefik.http.routers.authelia-https.entrypoints=web-secure"
      - "traefik.http.routers.authelia-https.tls=true"
      - "traefik.http.routers.authelia-https.tls.certresolver=letsencrypt"
      - "traefik.http.routers.authelia-https.service=authelia"
      - "traefik.http.routers.authelia-https.middlewares=hardened-public@file"

      - "traefik.http.services.authelia.loadbalancer.server.port=9091"

    networks:
      - proxy

volumes:
  authelia-data:

networks:
  proxy:
    external: true
    name: ${PROXY_NETWORK:-EDGEPROXY}
```

## Authelia config

`./config/configuration.yml`:

```yaml
server:
  address: tcp://0.0.0.0:9091/
  buffers:
    read: 4096
    write: 4096

log:
  level: info

theme: dark

totp:
  issuer: bauer-group.com

authentication_backend:
  file:
    path: /config/users.yml

# Access control: who can reach what.
access_control:
  default_policy: deny
  rules:
    # Public assets / health checks
    - domain: "auth.bauer-group.com"
      policy: bypass

    # All admin apps require 2FA
    - domain:
        - "admin.bauer-group.com"
        - "grafana.bauer-group.com"
      policy: two_factor
      subject:
        - "group:admins"

    # Internal tools require login (no 2FA)
    - domain: "*.internal.bauer-group.com"
      policy: one_factor
      subject:
        - "group:employees"

session:
  name: authelia_session
  same_site: lax
  inactivity: 1h
  expiration: 24h
  remember_me: 30d
  cookies:
    - domain: bauer-group.com
      authelia_url: https://auth.bauer-group.com

regulation:
  max_retries: 3
  find_time: 2m
  ban_time: 5m

storage:
  local:
    path: /var/lib/authelia/db.sqlite3

notifier:
  filesystem:
    filename: /var/lib/authelia/notifications.txt
  # For production: SMTP
  # smtp:
  #   address: 'submission://smtp.example.com:587'
  #   username: 'authelia'
  #   sender: 'authelia@bauer-group.com'
```

`./config/users.yml`:

```yaml
users:
  alice:
    displayname: "Alice Admin"
    # bcrypt hash of "password123"
    # generate: docker run --rm authelia/authelia:latest authelia hash-password password123
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."
    email: alice@bauer-group.com
    groups:
      - admins
      - employees
```

## Protect an app via forward-auth

In your app's compose, reference the `forward-auth-authelia@file`
middleware:

```yaml
labels:
  - "traefik.http.routers.${STACK_NAME}-https.middlewares=forward-auth-authelia@file,hardened-public@file"
```

`forward-auth-authelia@file` is pre-defined in CS-Traefik's
[`config/traefik/dynamic/middlewares.yml`](../../config/traefik/dynamic/middlewares.yml):

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

**Important**: the `address:` URL contains `auth.example.com` as the
default redirect. Override per-deployment by editing
`middlewares.yml` to use your actual auth URL:

```yaml
forward-auth-authelia:
  forwardAuth:
    address: "http://authelia:9091/api/verify?rd=https://auth.bauer-group.com"
    ...
```

Or define a per-app variant in your app's compose:

```yaml
labels:
  - "traefik.http.middlewares.${STACK_NAME}-auth.forwardauth.address=http://authelia:9091/api/verify?rd=https://auth.bauer-group.com"
  - "traefik.http.middlewares.${STACK_NAME}-auth.forwardauth.trustforwardheader=true"
  - "traefik.http.middlewares.${STACK_NAME}-auth.forwardauth.authresponseheaders=Remote-User,Remote-Groups,Remote-Email,Remote-Name"

  - "traefik.http.routers.${STACK_NAME}-https.middlewares=${STACK_NAME}-auth,hardened-public@file"
```

The latter is preferable for production deployments — the auth URL
becomes part of the app's stack config, not the proxy's global
config.

## Network routing requirement

Authelia needs to be reachable from Traefik via Docker DNS at
`http://authelia:9091`. This works if:

1. Authelia attaches to the `EDGEPROXY` proxy network (it does — see
   the compose above).
2. Authelia's compose service name OR hostname is `authelia`.

Verify:

```bash
docker exec edgeproxy-traefik nslookup authelia
# Should resolve to a 100.65.x.x address.
```

## Backend gets user info via headers

After Authelia authorizes, Traefik forwards the request to the
backend with these headers added:

```text
Remote-User: alice
Remote-Groups: admins,employees
Remote-Name: Alice Admin
Remote-Email: alice@bauer-group.com
```

Your app reads these headers (typically as `X-Forwarded-User` etc. —
some app frameworks rename them) and skips its own auth check.

⚠️ **Trust boundary**: the app must NEVER accept these headers from
direct (non-Traefik) traffic. If an attacker can hit the app
backend directly (bypassing Traefik), they can spoof the headers.
Mitigations:

- App network is internal-only (never exposed publicly via host
  ports).
- App server checks `X-Forwarded-Host` matches an expected proxy.
- App middleware strips the `Remote-*` headers if the request didn't
  come from the proxy IP.

## Logout

Authelia's session cookie is on `bauer-group.com` (root domain). To
log out, hit:

```text
https://auth.bauer-group.com/logout
```

The cookie is cleared, redirect chain returns to where you came
from, and the next request hits Authelia → not authenticated → login
prompt.

## Variants

### Authentik instead of Authelia

CS-Traefik also ships `forward-auth-authentik@file`. Same pattern,
different backend. Authentik has a richer admin UI but is heavier
(needs PostgreSQL + Redis).

### OAuth proxy (oauth2-proxy)

For external OIDC providers (Google, Microsoft, GitHub):

```yaml
oauth2-proxy:
  image: quay.io/oauth2-proxy/oauth2-proxy:latest
  command:
    - --provider=google
    - --client-id=...
    - --client-secret=...
    - --cookie-secret=...
    - --upstream=static://200
    - --http-address=0.0.0.0:4180
    - --reverse-proxy=true
    - --email-domain=bauer-group.com
  expose:
    - 4180/tcp
  networks:
    - proxy
```

Then a custom forward-auth middleware:

```yaml
- "traefik.http.middlewares.oauth-proxy.forwardauth.address=http://oauth2-proxy:4180/oauth2/auth"
- "traefik.http.middlewares.oauth-proxy.forwardauth.trustforwardheader=true"
- "traefik.http.middlewares.oauth-proxy.forwardauth.authresponseheaders=X-Auth-Request-User,X-Auth-Request-Email,X-Auth-Request-Access-Token"
```

## Common issues

### Infinite redirect loop

The auth service URL has a path-prefix collision with the protected
app. Solution: use a dedicated auth subdomain (`auth.bauer-group.com`),
not a path under an app's domain.

### Headers not arriving at backend

The `authResponseHeaders` must include the headers your app expects.
If your app reads `X-Forwarded-User`, you need to add that in
`authResponseHeaders` or rename Authelia's `Remote-User` via app
config. Check what's actually arriving:

```bash
docker exec my-app curl -H "Authorization: Bearer ..." \
  -v http://localhost:3000/debug-headers
```

### Authelia keeps prompting for login

Session cookie isn't sticking. Check:

- Authelia's `session.cookies.domain` matches your apex domain
  (`bauer-group.com`).
- Same-site policy is `lax` (not `strict`, which breaks redirects).
- The browser isn't blocking third-party cookies for your domain.
