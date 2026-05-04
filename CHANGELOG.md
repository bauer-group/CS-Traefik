## [0.1.2](https://github.com/bauer-group/CS-Traefik/compare/v0.1.1...v0.1.2) (2026-05-04)

### 🐛 Bug Fixes

* removed global HTTP→HTTPS redirect, added admin-host redirect ([2616904](https://github.com/bauer-group/CS-Traefik/commit/2616904b98605fd815f9848d847fa7c14873f52b))

# Changelog

All notable changes to CS-Traefik are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

* HTTP→HTTPS redirect is now **per-router**, not global at the entrypoint
  level. The previous default would intercept every HTTP request before
  router matching, making HTTP-only routes (webhooks, IoT endpoints, ACME
  challenges, dumb-LB health probes) impossible regardless of how an
  app's labels were configured. Restored to the legacy EDGEPROXY pattern
  where each app router decides via its own redirect middleware (e.g.
  the `${STACK_NAME}-redirect-to-secure` pattern in BG app stacks, or
  the `https-redirect@file` one-liner from `dynamic/middlewares.yml`).
  The block stays in `traefik.yml` as a commented-out reference for
  operators who genuinely want a global redirect.

* Added a dedicated HTTP→HTTPS redirect router for the admin FQDN that
  activates only when `API_HOST` is set. Single rule `Host(${API_HOST})`
  on the `web` entrypoint, with the IP whitelist applied so even the
  redirect isn't visible to non-whitelisted clients. Catches the entire
  admin surface (`/dashboard`, `/grafana`, `/prometheus`, `/alertmanager`)
  in one rule -- after redirect, the HTTPS routers handle their specific
  path prefixes.

### Changed

* CHANGELOG file restructured so the `# Changelog` title is the first
  line (fixes MD041 markdownlint warning) and the matching
  `changelogTitle` in `.github/config/release/semantic-release.json`
  ensures future automated releases insert new entries BELOW the title
  block instead of prepending above it.

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
