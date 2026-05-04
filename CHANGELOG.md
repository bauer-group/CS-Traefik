# Changelog

All notable changes to CS-Traefik are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

* **Internal Traefik entrypoint ports use upstream Traefik convention**
  rather than legacy v2 numbers, since these entrypoints never reach
  the host and have no external-compat constraint:
  * `metrics` is now on container-port `8082` (the port shown in the
    official Traefik docs for the metrics entrypoint).
  * `ping` is now on container-port `8081` (no canonical Traefik port
    for ping; clean neighbour to metrics 8082).
  * Both `traefik.yml` and `prometheus.yml` updated.

* **External port mappings now bind IPv4 + IPv6 explicitly**. Compose's
  bare `80:80` syntax binds only `0.0.0.0:80` (IPv4); kernels with
  `IPV6_V6ONLY=0` may auto-dual-stack via `[::]` but that is config-
  dependent and unreliable. Now every public port (80/tcp, 443/tcp,
  443/udp, ${API_PORT}/tcp) has TWO explicit bindings -- one for
  IPv4 and one for IPv6 -- so behaviour is portable across kernels
  and Docker versions. New `API_BIND_V6` env var controls the IPv6
  bind for the admin entrypoint, defaulting to `::1` (loopback only).

* **Internal network renamed to UPPERCASE** for naming consistency
  with the public network: `EDGEPROXY-internal` → `EDGEPROXY-INTERNAL`.
  Both networks now follow the same casing convention. Applies to:
  the `traefik.docker.network` labels in the monitoring overlay, the
  `name:` field on the network definition, and `.env.example` /
  README documentation. App stacks don't attach to this network so
  no app-side changes are required.

* **`.releaserc.json` added at repo root** mirroring the
  `.github/config/release/semantic-release.json` so semantic-release's
  auto-discovery picks up the `changelogTitle` config regardless of
  which path the reusable workflow looks at. Should fix the recurring
  "auto-prepended `## [X.Y.Z]` above the `# Changelog` H1" issue --
  the plugin now sees the title at the start of the file and inserts
  new release blocks BELOW it.

## [0.1.4](https://github.com/bauer-group/CS-Traefik/compare/v0.1.3...v0.1.4) (2026-05-04)

### 🐛 Bug Fixes

* **metrics:** moved Traefik metrics port 9100 -> 9080 (legacy + name clash) ([60c9b26](https://github.com/bauer-group/CS-Traefik/commit/60c9b26083bc5bee7f84e2bfbfdbf46c079d52c6))

## [0.1.3](https://github.com/bauer-group/CS-Traefik/compare/v0.1.2...v0.1.3) (2026-05-04)

### 🐛 Bug Fixes

* **timeouts:** restored legacy v2 respondingTimeouts on web entrypoints ([aa3068b](https://github.com/bauer-group/CS-Traefik/commit/aa3068be93eac334c310dcd967119748a752deed))

## [0.1.2](https://github.com/bauer-group/CS-Traefik/compare/v0.1.1...v0.1.2) (2026-05-04)

### 🐛 Bug Fixes

* removed global HTTP→HTTPS redirect, added admin-host redirect ([2616904](https://github.com/bauer-group/CS-Traefik/commit/2616904b98605fd815f9848d847fa7c14873f52b))

## [0.1.1](https://github.com/bauer-group/CS-Traefik/compare/v0.1.0...v0.1.1) (2026-05-03)

### 🐛 Bug Fixes

* **rate-limit:** raised baseline + added permissive variant for CGNAT ([19189be](https://github.com/bauer-group/CS-Traefik/commit/19189be7c072643133400c985fd0254b1c7c475d))

## [0.1.0](https://github.com/bauer-group/CS-Traefik/compare/v0.0.0...v0.1.0) (2026-05-03)

### 🚀 Features

* **acme:** reordered LE challenges + activated DNS-01 with all providers ([9e77357](https://github.com/bauer-group/CS-Traefik/commit/9e7735711297c868ec28089880a1500be695f06a))
* added CS-Traefik stack (Traefik v3.6 + observability) ([dd6c540](https://github.com/bauer-group/CS-Traefik/commit/dd6c5406a3320c72041d69f5e49734ad93089bc4))
* re-added resource caps on helpers (asymmetric: Traefik uncapped) ([1c8b136](https://github.com/bauer-group/CS-Traefik/commit/1c8b13667c54583f6afffdad4131249fe847ea3a))

### 🐛 Bug Fixes

* enabled non-blocking json-file logging on every service ([75ce366](https://github.com/bauer-group/CS-Traefik/commit/75ce36687d9bcd9d84bb0d6f08773b19c611fc2c))
* removed all deploy.resources.limits (latent bottleneck on edge proxy) ([400300a](https://github.com/bauer-group/CS-Traefik/commit/400300a7e0eed97ca195b027b02c4803a3b55475))
* restored legacy compat (entrypoints, surface, TLS defaults) ([8a16a31](https://github.com/bauer-group/CS-Traefik/commit/8a16a3143d0844feb76fd9b60674f7545fddd8f1))
