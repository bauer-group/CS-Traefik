# Custom Configuration (file provider)

For routes that aren't expressible as Docker labels — VMs, on-prem
appliances, external SaaS, multi-host backends, projects you'd rather
not touch the compose files of — Traefik's file provider is the
escape hatch.

## When to use file-provider routes

The file provider is for the **1 %** of cases that don't fit Docker
labels:

- The backend doesn't run in Docker (a legacy VM, a SaaS endpoint,
  a static IP on the LAN).
- The backend is outside this Compose project and you can't add
  labels to it.
- You want centrally-managed config (versioned with the proxy repo)
  rather than label-spam scattered across N app repos.
- You need advanced features that don't map cleanly to Docker labels
  (multi-cert routers, complex middleware chains, mirroring).

The other **99 %** of routes belong on the app side as Docker labels —
co-located with the service they describe, no central registry needed.

## How to add a route

Drop a `*.yml` (or `*.yaml`) file into
[`config/traefik/dynamic/`](../config/traefik/dynamic/) and Traefik picks
it up live (the file provider has `watch: true`).

A starter template lives at
[`config/traefik/dynamic/example-routes.yml.disabled`](../config/traefik/dynamic/example-routes.yml.disabled).
Files ending in `.disabled` are ignored — only `.yml` / `.yaml` are
loaded.

To activate:

```bash
cp config/traefik/dynamic/example-routes.yml.disabled \
   config/traefik/dynamic/my-routes.yml

# edit to taste
```

Save and Traefik picks up the changes within a few seconds. No
restart needed.

## Anatomy of a file-provider route

A complete route consists of:

```yaml
http:

  routers:
    legacy-vm-app:                              # router name (any unique string)
      rule: "Host(`legacy.bauer-group.com`)"    # match condition
      entryPoints:
        - web-secure
      service: legacy-vm-app                    # which service to route to
      tls:
        certResolver: letsencrypt
      middlewares:
        - hsts-mild@file
        - nosniff@file

  services:
    legacy-vm-app:
      loadBalancer:
        servers:
          - url: "http://10.20.30.40:8080"      # the actual backend
        passHostHeader: true
        responseForwarding:
          flushInterval: 100ms
        healthCheck:
          path: /health
          interval: 30s
          timeout: 5s
```

Three sections:

1. **`routers`** — match conditions + which service to forward to.
2. **`services`** — the actual backend(s) to forward to.
3. **`middlewares`** — defined elsewhere (in `middlewares.yml`) or
   inline here.

Reference middlewares from `middlewares.yml` with the `@file` suffix:

```yaml
middlewares:
  - hsts-mild@file
  - rate-limit@file
```

Reference middlewares defined in this same file by bare name (no
suffix):

```yaml
http:
  routers:
    foo:
      middlewares:
        - my-custom-middleware    # defined below in same file
  middlewares:
    my-custom-middleware:
      headers:
        customResponseHeaders:
          X-Custom: "Hello"
```

## File provider does NOT recurse

The file provider in [`config/traefik/traefik.yml`](../config/traefik/traefik.yml)
points at `directory: /etc/traefik/dynamic`. Subdirectories under
`dynamic/` are **not** scanned recursively.

Keep all custom YAML at the top level:

```text
config/traefik/dynamic/
├── middlewares.yml      ← shipped with CS-Traefik
├── tls.yml              ← shipped with CS-Traefik
├── my-routes.yml        ← your custom routes (loaded)
├── corp-tls.yml         ← your custom TLS options (loaded)
└── work-in-progress.yml.disabled  ← ignored (extension not .yml)
```

## Multiple files

Traefik concatenates **all** `*.yml` / `*.yaml` files in `dynamic/`
into one logical config. Names must be unique across all files:

```yaml
# my-routes.yml
http:
  routers:
    foo: ...

# corp-routes.yml -- ERROR: duplicate router name
http:
  routers:
    foo: ...
```

Pick names that include a project prefix or domain to avoid collisions
(`bgcorp-foo`, `customer-bar`).

## Common patterns

### Routing to a specific IP / port

Backend on a VM, on-prem appliance, or external service:

```yaml
http:
  routers:
    on-prem-erp:
      rule: "Host(`erp.bauer-group.local`)"
      entryPoints:
        - web-secure
      service: on-prem-erp
      tls:
        certResolver: letsencrypt-dns    # internal-only domain, DNS-01

  services:
    on-prem-erp:
      loadBalancer:
        servers:
          - url: "https://erp-server.bauer-group.local:8443"
        passHostHeader: true
        serversTransport: skip-tls-verify    # if backend has self-signed cert
```

### Multiple backends / load balancing

```yaml
http:
  services:
    backend-cluster:
      loadBalancer:
        servers:
          - url: "http://10.0.1.10:8080"
          - url: "http://10.0.1.11:8080"
          - url: "http://10.0.1.12:8080"
        passHostHeader: true
        sticky:
          cookie:
            name: lb_session
            secure: true
            httpOnly: true
        healthCheck:
          path: /healthz
          interval: 10s
          timeout: 3s
```

Traefik does round-robin by default; sticky sessions opt-in via
`sticky.cookie`.

### Routing to a Tailscale / WireGuard peer

If you have Tailscale on the Traefik host, it's just another IP:

```yaml
http:
  routers:
    remote-server:
      rule: "Host(`remote.bauer-group.com`)"
      entryPoints:
        - web-secure
      service: remote-server
      tls:
        certResolver: letsencrypt

  services:
    remote-server:
      loadBalancer:
        servers:
          - url: "http://100.65.200.42:8080"   # tailscale IP
        passHostHeader: true
```

### Custom middleware (inline)

Define + use in one file:

```yaml
http:
  routers:
    api-with-cors:
      rule: "Host(`api.bauer-group.com`)"
      entryPoints:
        - web-secure
      service: my-api
      tls:
        certResolver: letsencrypt
      middlewares:
        - api-cors

  middlewares:
    api-cors:
      headers:
        accessControlAllowOriginList:
          - "https://app.bauer-group.com"
          - "https://www.bauer-group.com"
        accessControlAllowMethods:
          - GET
          - POST
        accessControlAllowCredentials: true

  services:
    my-api:
      loadBalancer:
        servers:
          - url: "http://10.0.0.5:3000"
```

### TLS pass-through (TCP-level, no termination)

If you need raw TLS pass-through (e.g. for a backend that does its
own TLS termination):

```yaml
tcp:
  routers:
    raw-tls:
      rule: "HostSNI(`vpn.bauer-group.com`)"
      entryPoints:
        - web-secure
      service: raw-tls
      tls:
        passthrough: true

  services:
    raw-tls:
      loadBalancer:
        servers:
          - address: "10.0.0.50:443"
```

Note this uses `tcp` (not `http`) at the top level. The TCP router
matches on SNI without decrypting.

### Redirect outside the file provider

For redirects, the simplest pattern is a router with a redirect
middleware:

```yaml
http:
  routers:
    legacy-redirect:
      rule: "Host(`old.bauer-group.com`)"
      entryPoints:
        - web-secure
      service: noop      # required; never reached due to redirect
      tls:
        certResolver: letsencrypt
      middlewares:
        - to-new-domain

  middlewares:
    to-new-domain:
      redirectRegex:
        regex: "^https?://old\\.bauer-group\\.com(.*)"
        replacement: "https://new.bauer-group.com$1"
        permanent: true

  services:
    noop:                # placeholder, never reached
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:1"
```

Traefik requires every router to point at a service even if the
middleware short-circuits with a 301. Use a noop service.

## Testing the syntax

Before saving a custom config to `dynamic/`, run:

```bash
sudo ./traefik.sh validate
```

This validates `traefik.yml` + the dynamic dir. Errors point at the
offending line.

To check the result:

```bash
sudo ./traefik.sh logs traefik | tail -30
```

Look for `Configuration loaded from file: ...`. Errors show as
`level=error` entries with the file name and line.

## Reloading

The file provider has `watch: true` — saves are picked up within a
few seconds. No `traefik.sh restart` needed for dynamic config
changes.

The static config in `traefik.yml` requires a restart to apply
(entrypoints, providers, certResolvers).

## Examples in this repository

- [`examples/on-prem-vm-via-file-provider.md`](examples/on-prem-vm-via-file-provider.md) — full walk-through of routing to a VM.
- [`examples/wildcard-cert-cloudflare.md`](examples/wildcard-cert-cloudflare.md) — DNS-01 wildcard cert via file-provider router.
