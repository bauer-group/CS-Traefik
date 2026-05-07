## [0.9.11](https://github.com/bauer-group/CS-Traefik/compare/v0.9.10...v0.9.11) (2026-05-07)

### 🐛 Bug Fixes

* **watchtower:** reverted log format default to auto for stack consistency ([80a3515](https://github.com/bauer-group/CS-Traefik/commit/80a351518dc163b83f769abfc5baa0328e004f03))

## [0.9.10](https://github.com/bauer-group/CS-Traefik/compare/v0.9.9...v0.9.10) (2026-05-07)

### 🐛 Bug Fixes

* **watchtower:** switched to marrrrrrrrry fork and re-enabled rolling restart ([0cc4b97](https://github.com/bauer-group/CS-Traefik/commit/0cc4b975cd145227e5a260bd7c03cd32a21df2ab))

## [0.9.9](https://github.com/bauer-group/CS-Traefik/compare/v0.9.8...v0.9.9) (2026-05-07)

### 🐛 Bug Fixes

* **watchtower:** comment out WATCHTOWER_ROLLING_RESTART to prevent unintended behavior ([9843525](https://github.com/bauer-group/CS-Traefik/commit/9843525bcd239475f424627a0a68470f9263ee76))

## [0.9.8](https://github.com/bauer-group/CS-Traefik/compare/v0.9.7...v0.9.8) (2026-05-07)

### 🐛 Bug Fixes

* **watchtower:** dropped WATCHTOWER_ROLLING_RESTART so monitoring stack does not loop ([ae7797d](https://github.com/bauer-group/CS-Traefik/commit/ae7797de8d703b23652cd941138017eee16779c3))

## [0.9.7](https://github.com/bauer-group/CS-Traefik/compare/v0.9.6...v0.9.7) (2026-05-07)

### 🐛 Bug Fixes

* **routing:** added Path(\`/\`) to dashboard routers so bare-host redirect actually fires ([2b92d43](https://github.com/bauer-group/CS-Traefik/commit/2b92d43ae35f2699774aea4c21c869eff1314b48))

## [0.9.6](https://github.com/bauer-group/CS-Traefik/compare/v0.9.5...v0.9.6) (2026-05-07)

### 🐛 Bug Fixes

* **installer,wizard:** added missing print_section + tightened wizard defaults ([a9830f2](https://github.com/bauer-group/CS-Traefik/commit/a9830f2227dc14c0709d5e4821f6187ca1fc763b))

## [0.9.5](https://github.com/bauer-group/CS-Traefik/compare/v0.9.4...v0.9.5) (2026-05-07)

### 🐛 Bug Fixes

* **docker-compose:** remove redundant comments about v2 network subnets ([072aa48](https://github.com/bauer-group/CS-Traefik/commit/072aa481a9b95dbfd598a1f8f478d98ba5146370))

## [0.9.4](https://github.com/bauer-group/CS-Traefik/compare/v0.9.3...v0.9.4) (2026-05-07)

### ⏪ Reverts

* **networking:** restored v2-identical CGNAT subnets, hardcoded ([9cf73ab](https://github.com/bauer-group/CS-Traefik/commit/9cf73abc640af317a0d5d3570e10658b9dacfea8))

## [0.9.3](https://github.com/bauer-group/CS-Traefik/compare/v0.9.2...v0.9.3) (2026-05-07)

### 🐛 Bug Fixes

* **networking,wizard,grafana:** real fixes from production install run ([9459fd8](https://github.com/bauer-group/CS-Traefik/commit/9459fd8d0f05573ad7373a33aeb17429d378d053))

## [0.9.2](https://github.com/bauer-group/CS-Traefik/compare/v0.9.1...v0.9.2) (2026-05-07)

### 🐛 Bug Fixes

* **installer,wizard:** made curl|bash flow actually work + minimal .env output ([933a34d](https://github.com/bauer-group/CS-Traefik/commit/933a34d390272bf826bfd82b8dd6f4f0baba48ef))

## [0.9.1](https://github.com/bauer-group/CS-Traefik/compare/v0.9.0...v0.9.1) (2026-05-07)

### 🐛 Bug Fixes

* **installer,cli:** TTY fallback for curl|bash + consistent post-action summaries ([d4b8168](https://github.com/bauer-group/CS-Traefik/commit/d4b8168457056c4c76ad7fae7c7452632b9c5ad3))

## [0.9.0](https://github.com/bauer-group/CS-Traefik/compare/v0.8.1...v0.9.0) (2026-05-07)

### 🚀 Features

* **installer:** added `upgrade` subcommand for batch v2->v3 migration ([a2150b5](https://github.com/bauer-group/CS-Traefik/commit/a2150b5b46eab06401ee61565a1340ec37b64fae))

## [0.8.1](https://github.com/bauer-group/CS-Traefik/compare/v0.8.0...v0.8.1) (2026-05-07)

### 🐛 Bug Fixes

* **layout:** default DATA_DIRECTORY to ./data, never the install dir itself ([9b9e357](https://github.com/bauer-group/CS-Traefik/commit/9b9e35792899f27861a44c0894f3940d70274d5c))

## [0.8.0](https://github.com/bauer-group/CS-Traefik/compare/v0.7.0...v0.8.0) (2026-05-07)

### 🚀 Features

* **stability:** light Traefik OOM bias + small-host-safe defaults + no pids_limit ([4b91743](https://github.com/bauer-group/CS-Traefik/commit/4b91743c70a7ec51adbcb64b83ea431e1dae5b86))

## [0.7.0](https://github.com/bauer-group/CS-Traefik/compare/v0.6.0...v0.7.0) (2026-05-07)

### 🚀 Features

* **monitoring:** rounded out the dashboard set -- 4 new + 6 enhanced (Tier 1+2+3+4) ([72d1343](https://github.com/bauer-group/CS-Traefik/commit/72d13437d128fdc76f1a2e34006774e0ff2b5fba))

## [0.6.0](https://github.com/bauer-group/CS-Traefik/compare/v0.5.5...v0.6.0) (2026-05-06)

### 🚀 Features

* **monitoring,migration:** added 4 production-grade dashboards + ACME v2->v3 cert migration tool ([dc3fb7c](https://github.com/bauer-group/CS-Traefik/commit/dc3fb7c05f0d2818986f6cf87fb9f832a4857ff3))

## [0.5.5](https://github.com/bauer-group/CS-Traefik/compare/v0.5.4...v0.5.5) (2026-05-06)

### 🐛 Bug Fixes

* **monitoring:** repaired silent end-to-end alerting break -- alertmanager path_prefix ([13bb4a7](https://github.com/bauer-group/CS-Traefik/commit/13bb4a75b4b81b256d42ad0a09e918825449458f))

## [0.5.4](https://github.com/bauer-group/CS-Traefik/compare/v0.5.3...v0.5.4) (2026-05-05)

### 🐛 Bug Fixes

* **monitoring:** repaired six bugs uncovered by full-stack Docker Desktop test ([99e3f04](https://github.com/bauer-group/CS-Traefik/commit/99e3f0446e371b9f992af0f8ca11ac43d5547080))

## [0.5.3](https://github.com/bauer-group/CS-Traefik/compare/v0.5.2...v0.5.3) (2026-05-04)

### ♻️ Refactoring

* **env:** adopted dual-layout .env.example -- 6 active values, everything else commented with inline reference ([fbcdc7b](https://github.com/bauer-group/CS-Traefik/commit/fbcdc7b32449fd5811cc95499736c5d7605cb91c))

## [0.5.2](https://github.com/bauer-group/CS-Traefik/compare/v0.5.1...v0.5.2) (2026-05-04)

### 🐛 Bug Fixes

* **admin-access:** three-tier priorities + local fail-closed pattern for unset API_HOST ([373d3d9](https://github.com/bauer-group/CS-Traefik/commit/373d3d9313e29ef478231bb04d153440be5ac692))

## [0.5.1](https://github.com/bauer-group/CS-Traefik/compare/v0.5.0...v0.5.1) (2026-05-04)

### 🐛 Bug Fixes

* **admin-access:** pinned explicit priorities on all four admin routers to prevent silent shadowing ([249b970](https://github.com/bauer-group/CS-Traefik/commit/249b970d43169a38a7cc3e409fcfc8da4d6e3163))

## [0.5.0](https://github.com/bauer-group/CS-Traefik/compare/v0.4.2...v0.5.0) (2026-05-04)

### 🚀 Features

* **admin-access:** split internal vs external admin routing -- monitoring stack auto-allowed, API_WHITELIST scoped to external only ([a25e60b](https://github.com/bauer-group/CS-Traefik/commit/a25e60bf2af73d54ec26527add0f9985ed29f5d3))

## [0.4.2](https://github.com/bauer-group/CS-Traefik/compare/v0.4.1...v0.4.2) (2026-05-04)

### 🐛 Bug Fixes

* **admin-access:** whitelisted EDGEPROXY-INTERNAL subnet so monitoring stack can reach admin endpoints ([a4a6411](https://github.com/bauer-group/CS-Traefik/commit/a4a64116387d22a5a41d7342894734de7b81af3b))

## [0.4.1](https://github.com/bauer-group/CS-Traefik/compare/v0.4.0...v0.4.1) (2026-05-04)

### 🐛 Bug Fixes

* **security+docs:** rotated example BCrypt hash and corrected bg-provider reach claim ([a19784d](https://github.com/bauer-group/CS-Traefik/commit/a19784d05b587297732ecea0c96ed40073e5030d))

## [0.4.0](https://github.com/bauer-group/CS-Traefik/compare/v0.3.2...v0.4.0) (2026-05-04)

### 🚀 Features

* **tls:** added opt-in *.bauer-group.com wildcard certificate template ([86641b6](https://github.com/bauer-group/CS-Traefik/commit/86641b6ce6781ed027d7ac6134917f30f0a33494))

## [0.3.2](https://github.com/bauer-group/CS-Traefik/compare/v0.3.1...v0.3.2) (2026-05-04)

### 🐛 Bug Fixes

* **static-config:** repaired Traefik v3.6 startup failures ([4bead03](https://github.com/bauer-group/CS-Traefik/commit/4bead034c3d07948c555dc232fcaaada55214ec2))

## [0.3.1](https://github.com/bauer-group/CS-Traefik/compare/v0.3.0...v0.3.1) (2026-05-04)

### ♻️ Refactoring

* **compression:** raised minResponseBodyBytes from 50 to 256 ([fd2385c](https://github.com/bauer-group/CS-Traefik/commit/fd2385c4cb5ee10a97b49a023c5b27fce0e05470))

## [0.3.0](https://github.com/bauer-group/CS-Traefik/compare/v0.2.0...v0.3.0) (2026-05-04)

### 🚀 Features

* tunable respondingTimeouts + tighter compression threshold + BG email default ([8e2e8ff](https://github.com/bauer-group/CS-Traefik/commit/8e2e8fffca59894a1072b626b609f30f311dbb86))

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
