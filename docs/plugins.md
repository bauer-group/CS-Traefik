# Optional Plugins

Three Traefik plugins are recommended for BG edge deployments when
the built-in middlewares hit their limits. **None are enabled by
default** — the standard `traefik.yml` ships with no
`experimental.plugins:` block at all, so the stack has zero plugin-
related dependencies, zero plugin-related startup latency, and zero
exposure to plugin-registry availability out of the box.

This document is the recipe book for enabling them on demand.

## How Traefik plugins differ from built-in middlewares

| Aspect | Built-in middleware | Plugin |
| --- | --- | --- |
| Source | Compiled into the Traefik binary | Downloaded from `plugins.traefik.io` at first container start |
| First-boot cost | None | ~10–30 s download + Yaegi compile per plugin |
| External dependency | None | Plugin registry must be reachable |
| Failure mode | None (always available) | Container fails to start if the registry is down or the version doesn't resolve |
| Updates | Pinned to the Traefik image tag | Independent semver pin per plugin |
| Activation | Reference by name (`@file` or via labels) | Two steps: declare in static config, then reference |

The trade-off: plugins are powerful (CrowdSec threat-intel, GeoIP
blocking, on-demand container wake) but trade away the
"single-binary, no external services" simplicity of vanilla Traefik.
Enable them when you have a concrete use case, not "just in case."

## Activation recipe (applies to all three plugins)

Two file edits + one restart, then app-level Docker labels.

### Step 1 — declare the plugin in `config/traefik/traefik.yml`

Add (or replace) the `experimental:` block at the very bottom of the
file. **Pick only the plugins you actually need** — every declaration
adds startup latency and a registry dependency.

```yaml
experimental:
  plugins:
    crowdsec-bouncer:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.6.0
    geoblock:
      moduleName: github.com/PascalMinder/geoblock
      version: v0.3.7
    sablier:
      moduleName: github.com/sablierapp/sablier
      version: v1.11.2
```

Always pin to a specific `version:` tag — never `main` or a moving
branch. Plugin updates are reviewed and rolled out deliberately,
not absorbed silently.

### Step 2 — restart Traefik

```bash
docker compose restart traefik
```

Watch the logs on first start; expect a brief delay while plugins
download and compile:

```bash
docker compose logs -f traefik
# Look for: "Loading plugin <name>" lines, then the usual
# "Configuration loaded" line. Total delay scales linearly with
# plugin count -- 3 plugins ~30-60 s on typical hardware.
```

If a plugin fails to download (registry hiccup, version typo, GitHub
rate limit on a fresh IP), Traefik **fails the entire startup**.
Roll back by reverting the `experimental:` block and restarting.

### Step 3 — instantiate per-app via Docker labels

The plugin is now AVAILABLE but not yet APPLIED. Each app that needs
the protection adds its own middleware instance via Compose labels.
The recipes below cover the three plugins.

## CrowdSec Bouncer

**Use case**: block IPs that the CrowdSec threat-intel network has
flagged as malicious — botnet members, credential-stuffers, scrapers,
known DDoS sources. CrowdSec's value proposition is **collective**
intelligence: many honeypots feed one shared blocklist that updates
in near real-time.

**Module**: `github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin`
**Version**: `v1.6.0`
**External requirement**: a CrowdSec LAPI (Local API) instance
reachable from the Traefik container. Run as a sidecar service on
the same network or use the official CrowdSec Hub image.

### Minimal app-side labels (stream mode)

Stream mode pulls the blocklist on a timer and answers in-memory —
the fastest path, recommended for production:

```yaml
labels:
  - "traefik.enable=true"

  # Plugin middleware definition
  - "traefik.http.middlewares.cs-bouncer.plugin.crowdsec-bouncer.enabled=true"
  - "traefik.http.middlewares.cs-bouncer.plugin.crowdsec-bouncer.crowdsecMode=stream"
  - "traefik.http.middlewares.cs-bouncer.plugin.crowdsec-bouncer.crowdsecLapiHost=crowdsec:8080"
  - "traefik.http.middlewares.cs-bouncer.plugin.crowdsec-bouncer.crowdsecLapiKey=${CROWDSEC_LAPI_KEY}"
  - "traefik.http.middlewares.cs-bouncer.plugin.crowdsec-bouncer.updateIntervalSeconds=15"

  # Apply on the router
  - "traefik.http.routers.myapp.middlewares=cs-bouncer"
```

Set `CROWDSEC_LAPI_KEY` in the app stack's `.env` — never inline.
Stack-level secrets stay with the stack, not the proxy.

### Mode notes

- `stream` (recommended) — pulls blocklist updates from LAPI on a
  timer (default 60 s). Cheap to query (in-memory). Brief lag
  between block decision and enforcement.
- `live` — queries LAPI per request. Highest accuracy but adds
  latency to every request. Only use for low-traffic high-stakes
  endpoints.
- `appsec` — full WAF mode, runs CrowdSec's AppSec component.
  Heaviest; document its rules carefully before enabling.

## GeoBlock

**Use case**: allow or deny requests by source-IP country. Common
drivers: compliance ("no traffic from sanctioned countries"), DPO
guidance ("this app is GDPR-EU only"), abuse mitigation ("90 % of
brute-force is from countries we have no customers in"). **Not** a
substitute for proper authentication — IP-geo lookups can be wrong
or evaded with a VPN.

**Module**: `github.com/PascalMinder/geoblock`
**Version**: `v0.3.7`
**External requirement**: a GeoIP lookup endpoint. The plugin uses a
free public API by default (`get.geojs.io`); for production traffic
host your own (MaxMind GeoLite2 + a small wrapper) to avoid rate
limits.

### Allow-list mode (only DE / AT / CH)

```yaml
labels:
  - "traefik.enable=true"

  # Plugin middleware definition
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.allowLocalRequests=true"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.logLocalRequests=false"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.logAllowedRequests=false"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.logApiRequests=true"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.api=https://get.geojs.io/v1/ip/country/{ip}"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.apiTimeoutMs=750"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.cacheSize=15000"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.forceMonthlyUpdate=true"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.allowUnknownCountries=false"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.unknownCountryApiResponse=nil"
  - "traefik.http.middlewares.geo-dach.plugin.geoblock.countries=DE,AT,CH"

  # Apply on the router
  - "traefik.http.routers.myapp.middlewares=geo-dach"
```

`allowLocalRequests=true` always permits private-range source IPs
(RFC 1918, loopback, IPv6 link-local) — required so internal
healthchecks and Docker-network sidecar calls aren't blocked.

### Deny-list mode (block specific countries, allow everything else)

The plugin has no native deny-list mode — invert by listing all
ALLOWED countries minus the unwanted ones. ISO-3166-1 alpha-2 codes
are listed at [iso.org/obp/ui/#search](https://www.iso.org/obp/ui/#search).

## Sablier

**Use case**: scale rarely-used containers to zero, wake them on
demand when a request arrives. Saves RAM/CPU on staging
environments, dev tools, low-traffic internal apps. **Adds latency**
on the first request after sleep (container start time, often 5-30 s).

**Module**: `github.com/sablierapp/sablier`
**Version**: `v1.11.2`
**External requirement**: the Sablier service itself, running on the
same Docker network as Traefik. Sablier needs Docker socket access
to start/stop containers — same blast radius as Traefik's own socket
mount, plan accordingly.

### Sablier service (run alongside Traefik)

```yaml
# Inside the same Compose project as the slept-app, OR as its own stack
sablier:
  image: sablierapp/sablier:1.11.2
  container_name: sablier
  command:
    - start
    - --provider.name=docker
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
  networks:
    - proxy
  restart: unless-stopped
```

### App-side labels (Sablier-managed app)

```yaml
labels:
  - "traefik.enable=true"

  # Plugin middleware -- Sablier wakes the named container on incoming
  # requests, holds the request until ready, then proxies through.
  - "traefik.http.middlewares.wake-myapp.plugin.sablier.sablierUrl=http://sablier:10000"
  - "traefik.http.middlewares.wake-myapp.plugin.sablier.names=myapp"
  - "traefik.http.middlewares.wake-myapp.plugin.sablier.sessionDuration=10m"
  - "traefik.http.middlewares.wake-myapp.plugin.sablier.dynamic.displayName=My App"
  - "traefik.http.middlewares.wake-myapp.plugin.sablier.dynamic.theme=ghost"

  # Apply on the router
  - "traefik.http.routers.myapp.middlewares=wake-myapp"
```

`sessionDuration` keeps the container awake for that long after the
last request. Tune to your usage pattern: too short → slow rewakes;
too long → defeats the point of scaling to zero.

## Combining plugins

Plugins are middlewares like any other — chain them in the order
defenses should run, cheapest-first:

```yaml
- "traefik.http.routers.myapp.middlewares=geo-dach,cs-bouncer,wake-myapp,nosniff@file"
```

Reading left to right: drop non-DACH traffic before paying for a
CrowdSec lookup; check CrowdSec before paying for a Sablier wake;
wake the container before a useless backend request; finally add
`nosniff` security headers. Each step short-circuits cheaper than
the next.

## Disabling a plugin

To remove a plugin:

1. Remove its `experimental.plugins.<name>:` entry from `traefik.yml`.
2. Remove every Docker label that references it from app stacks.
3. Restart Traefik.

The plugin binary stays in Traefik's plugin cache directory but is
ignored. Wipe the cache with `docker compose down && docker volume
prune` if disk space matters.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Container stuck "starting" for >2 minutes on first plugin enable | Plugin download in progress. Watch `docker compose logs -f traefik` for "Loading plugin" lines. |
| Container fails immediately with "plugin not found" | Module name typo or version tag doesn't exist on GitHub. |
| Plugin loads but middleware reference is rejected | Plugin name in labels (`crowdsec-bouncer`) must MATCH the key under `experimental.plugins.<key>:` exactly. |
| App returns 502 / 503 with no log entry from the app | Plugin (CrowdSec / GeoBlock / Sablier) blocked or paused the request. Check Traefik access logs for the middleware decision. |
| GeoBlock returns 403 for known-good IPs | API rate limit (`get.geojs.io` shared limit hit). Switch to a self-hosted MaxMind backend. |

## Plugin catalog

The full Traefik plugin catalog lives at
[plugins.traefik.io](https://plugins.traefik.io). ~150 plugins are
available. The three documented here are picked
for the typical BG edge use case (threat intel, geo policy,
on-demand scaling) — others may suit specific scenarios:

- **Souin** (caching) — for high-traffic static-content endpoints
- **Real-IP** (header rewriting) — for upstream-proxied stacks
- **JWT validation** — when forward-auth (Authelia / Authentik)
  isn't desired
- **Plugin Demo** (`github.com/traefik/plugindemo`) — official
  example, useful for verifying that the plugin pipeline works at
  all before pinning a real plugin

When evaluating a candidate plugin: check the GitHub repo for
recent commits, open issues, and whether the maintainer responds.
A stale plugin pinned at a Traefik-incompatible version becomes
load-bearing technical debt fast.
