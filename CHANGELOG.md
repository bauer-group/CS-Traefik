# Changelog

All notable changes to CS-Traefik are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

* `respondingTimeouts` on `web` + `web-secure` entrypoints reset to the
  legacy v2 EDGEPROXY values: `readTimeout=0s`, `writeTimeout=0s`,
  `idleTimeout=180s`. The previous 60s/60s/180s defaults silently broke:
  * Large file uploads over slow / mobile links (DocumentSigning S3
    multipart pushes via MinIO routinely take >60s for 100MB+ PDFs).
  * Server-Sent Events (SSE) / streaming responses that need to hold
    the connection open for minutes.
  * Webhooks with long-running server-side logic (signing seal,
    document conversion).
  Note: Traefik v3 ships a new default of `readTimeout=60s` (v2 default
  was `0s`) -- this is a v2→v3 migration footgun the upstream changelog
  doesn't highlight loudly. We override back to v2 behaviour for
  byte-for-byte compat with the legacy stack. Slowloris consideration
  documented in `traefik.yml`; in BG production environments the legacy
  values have been used for years without incident.

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
