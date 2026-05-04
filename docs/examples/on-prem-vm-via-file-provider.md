# Example: Routing to an On-Prem VM via File Provider

When the backend isn't a Docker container — a legacy VM, an on-prem
appliance, an external SaaS — the file provider is the right
mechanism. Traefik forwards requests just like to a Docker service,
but the backend is whatever URL/IP you specify.

## Use cases

- Legacy VM running on VMware / Hyper-V on the same network.
- Network-attached storage with a web UI.
- On-prem ERP / CRM that can't be containerised.
- External SaaS you want to reverse-proxy (rare; usually it's the
  other way around).
- Service on a remote host reached via Tailscale / WireGuard mesh.

## Compose-based pattern doesn't work here

The `traefik.http.routers.X.rule=...` Docker label pattern only
works for containers Traefik can discover via the Docker socket.
A VM on the LAN doesn't have a Docker socket. That's where file
provider routes come in.

## File provider route

Drop a YAML file into [`config/traefik/dynamic/`](../../config/traefik/dynamic/).
Traefik picks it up live (no restart needed).

`config/traefik/dynamic/legacy-erp.yml`:

```yaml
http:

  routers:

    legacy-erp:
      rule: "Host(`erp.bauer-group.com`)"
      entryPoints:
        - web-secure
      service: legacy-erp
      tls:
        certResolver: letsencrypt
      middlewares:
        - hardened-public@file

    # HTTP redirect (per-router pattern, like the Docker-based examples)
    legacy-erp-http:
      rule: "Host(`erp.bauer-group.com`)"
      entryPoints:
        - web
      service: noop
      middlewares:
        - https-redirect@file

  services:

    legacy-erp:
      loadBalancer:
        servers:
          - url: "http://10.20.30.40:8080"
        passHostHeader: true
        healthCheck:
          path: /health
          interval: 30s
          timeout: 5s

    # Required because every router needs a service even when it
    # only ever short-circuits via redirect middleware.
    noop:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:1"
```

That's it. Save the file, Traefik notices within ~5 seconds, and
`https://erp.bauer-group.com` now forwards to `http://10.20.30.40:8080`.

## What's happening

- **Router `legacy-erp`** — matches `Host(\`erp.bauer-group.com\`)` on
  the HTTPS entrypoint. Apply standard hardened-public middleware
  chain. Forward to the `legacy-erp` service.
- **Service `legacy-erp`** — single-server load-balancer pointing at
  the VM. `passHostHeader: true` means the VM sees the original
  `Host: erp.bauer-group.com` header (not Traefik's internal name).
  Health check pings `/health` every 30s; if the VM is down, Traefik
  short-circuits to 502 instead of timing out.
- **Router `legacy-erp-http`** — matches the same hostname on the
  HTTP entrypoint, redirects to HTTPS. Required because we don't
  have a global redirect (per-router pattern). Points at a `noop`
  service because every router needs one.

## Backend with a self-signed certificate

If the VM serves HTTPS with a self-signed or corporate-CA cert that
Traefik doesn't trust, you have three options:

### Option A: Skip TLS verification (simplest, weakest)

Add a transport that skips verify, attach to the service:

```yaml
http:
  services:
    legacy-erp:
      loadBalancer:
        servers:
          - url: "https://10.20.30.40:8443"
        serversTransport: skip-tls-verify

  serversTransports:
    skip-tls-verify:
      insecureSkipVerify: true
```

Traefik's connection to the backend ignores cert errors. Edge-side
TLS to the user is still legit.

### Option B: Pin the backend cert (strongest)

Add the backend's cert to a trusted set:

```yaml
http:
  serversTransports:
    erp-pinned:
      rootCAs:
        - /etc/traefik/certs/static/erp-internal-ca.pem
      serverName: erp.internal.bauer-group.com

  services:
    legacy-erp:
      loadBalancer:
        servers:
          - url: "https://10.20.30.40:8443"
        serversTransport: erp-pinned
```

Drop `erp-internal-ca.pem` into `config/certs/static/` first.

### Option C: Just use HTTP to the backend (simplest if internal-only)

If the network between Traefik and the VM is trusted (same VLAN,
same physical link, MACSec-encrypted, ...), just talk HTTP. Edge
TLS still protects the public hop:

```yaml
servers:
  - url: "http://10.20.30.40:8080"      # plain HTTP to the VM
```

## Multiple backends with load-balancing

```yaml
http:
  services:
    erp-cluster:
      loadBalancer:
        servers:
          - url: "http://10.20.30.40:8080"
          - url: "http://10.20.30.41:8080"
          - url: "http://10.20.30.42:8080"
        passHostHeader: true
        sticky:
          cookie:
            name: erp_session
            secure: true
            httpOnly: true
        healthCheck:
          path: /health
          interval: 10s
          timeout: 3s
```

Traefik does round-robin by default; sticky sessions opt-in via
`sticky.cookie`. Health-check failures take a server out of rotation
automatically — surviving servers keep serving.

## Routing to a Tailscale peer

If you have Tailscale on the Traefik host, peers are just IPs in the
`100.64.0.0/10` range. Same pattern as the LAN example:

```yaml
http:
  services:
    remote-server:
      loadBalancer:
        servers:
          - url: "http://100.65.200.42:8080"   # tailscale IP of remote
        passHostHeader: true
```

Traefik forwards the request via the host's Tailscale interface. No
extra config needed.

## Routing to an external SaaS

```yaml
http:
  services:
    saas-passthrough:
      loadBalancer:
        servers:
          - url: "https://api.someprovider.com"
        passHostHeader: false       # let the SaaS see its own hostname
        responseForwarding:
          flushInterval: 100ms
```

`passHostHeader: false` is important — the SaaS gets `Host:
api.someprovider.com` instead of your hostname, otherwise it might
return a redirect to its real hostname or refuse to serve.

The router's match rule is on YOUR hostname, but the upstream `Host`
is the SaaS's hostname. Effectively you become a proxy for the
SaaS's API.

⚠️ **Be careful with caching, headers, and SaaS terms-of-service**.
This pattern can violate API ToS depending on the SaaS.

## Routing only certain paths to the VM

Combine `Host(...)` with `PathPrefix(...)`:

```yaml
http:
  routers:
    legacy-api:
      rule: "Host(`api.bauer-group.com`) && PathPrefix(`/v1/legacy`)"
      service: legacy-erp
      entryPoints:
        - web-secure
      tls:
        certResolver: letsencrypt
      middlewares:
        - strip-prefix-legacy-v1
        - hardened-api@file

  middlewares:
    strip-prefix-legacy-v1:
      stripPrefix:
        prefixes:
          - /v1/legacy
```

- Public URL: `https://api.bauer-group.com/v1/legacy/users`
- VM receives: `http://10.20.30.40:8080/users` (path stripped)
- Other paths under `api.bauer-group.com` go to other routers.

## Disabling

To disable a file-provider route, rename the file to add `.disabled`:

```bash
mv config/traefik/dynamic/legacy-erp.yml config/traefik/dynamic/legacy-erp.yml.disabled
```

Traefik notices within ~5s and removes the routes. The VM is
unreachable through Traefik until you rename back.

## Validating

```bash
sudo /opt/edgeproxy/traefik.sh validate
```

YAML syntax check + Traefik config sanity check. Errors point at the
offending line.

To see live what Traefik picked up:

```bash
sudo /opt/edgeproxy/traefik.sh logs traefik | tail -20
# Look for: "Configuration loaded from file: ..."
```

In the dashboard (`http://127.0.0.1:9090/dashboard/`):

- HTTP → Routers → `legacy-erp@file`
- HTTP → Services → `legacy-erp@file` → server `http://10.20.30.40:8080`

The `@file` suffix tells you the route came from a YAML file, not
Docker labels.
