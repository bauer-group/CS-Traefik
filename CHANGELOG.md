# Changelog

All notable changes to CS-Traefik are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file is maintained automatically by semantic-release. Do not
edit manually -- write a Conventional Commit on `main` and the
release pipeline will append the entry on the next run.

## [0.2.0](https://github.com/bauer-group/CS-Traefik/compare/v0.1.5...v0.2.0) (2026-05-04)

### 🚀 Features

* bg-provider always-on + middleware catalog + comprehensive docs/ ([b205905](https://github.com/bauer-group/CS-Traefik/commit/b2059056097893dd0b93e58d7f02835ff78ae901))

## [0.1.5](https://github.com/bauer-group/CS-Traefik/compare/v0.1.4...v0.1.5) (2026-05-04)

### 🐛 Bug Fixes

* **compat:** standard internal ports + dual-stack bindings + INTERNAL casing ([ceaa84c](https://github.com/bauer-group/CS-Traefik/commit/ceaa84cf80dcae8e91b764255c8dbfe0066dc83b))

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
