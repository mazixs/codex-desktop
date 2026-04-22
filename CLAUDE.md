# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Unofficial Linux packaging of OpenAI's macOS-only Codex Desktop Electron app. The repo does **not** contain Codex source — it downloads the upstream `Codex.dmg`, extracts `app.asar`, rebuilds macOS-native modules for Linux, patches the minified Electron main bundle, and packages portable/Arch/Debian artifacts.

Because patches target a minified upstream bundle via exact string replacement, upstream version bumps routinely break string-based patches. The build is explicitly a "maintained compatibility layer," not a stable port.

## Common Commands

All Node/pnpm commands run from `codex-linux-build/`:

```bash
pnpm install --frozen-lockfile      # install pinned deps (pnpm is required, not npm)
pnpm run build                      # download DMG, extract, patch, produce dist/
pnpm run build:clean                # same as build but wipes local build outputs first
pnpm run package:portable           # produce portable .tar.gz in artifacts/
pnpm run verify                     # bash -n syntax check + --help smoke on every shell entrypoint
./start.sh                          # launch the built app from dist/
```

Repo-level automation runs from the repo root:

```bash
./scripts/validate-workflows.sh                     # actionlint + shellcheck on .github/workflows
./scripts/build-arch-package.sh --source codex-linux-build/artifacts/*.tar.gz \
    --metadata codex-linux-build/artifacts/build-metadata.env \
    --output-dir codex-linux-build/artifacts        # portable .tar.gz → Arch pkg.tar.zst
./scripts/build-deb-package.sh    --source ... --metadata ... --output-dir ...   # portable → .deb
./scripts/generate-release-notes.sh --ref vX.Y.Z --metadata .../build-metadata.env
```

There is **no unit test suite**. Validation is contract-driven: `pnpm run verify` for shell syntax, `verify-portable-artifact.sh` / `verify-arch-package.sh` / `verify-deb-package.sh` / `verify-release-assets.sh` for build outputs. CI runs these; reproduce locally before opening PRs.

## Architecture

### Build pipeline (`codex-linux-build/build.sh`)

Single Bash script orchestrating the full adaptation. Key stages:

1. **Download** `Codex.dmg` from `CODEX_DMG_URL` (pinned to OpenAI's static CDN by default).
2. **Extract** the DMG via `7z`, then `asar` to unpack `app.asar` into `codex_extracted/app_unpacked/`.
3. **Rebuild native modules** for Linux x64 against Electron headers (pinned via `ELECTRON_VERSION`, currently 40.0.0):
   - `better-sqlite3` — reinstalled from npm, rebuilt via `@electron/rebuild`
   - `node-pty` — replaced entirely (macOS PTY bridge → Linux PTY impl)
   - `sparkle` — macOS-only auto-updater, deleted outright
4. **Patch the minified bundle.** Upstream uses Vite code-splitting with content-hashed filenames (`main-<hash>.js`, `deeplinks-<hash>.js`) loaded from `.vite/build/bootstrap.js`. Hashes change per upstream release, so the script **discovers bundles dynamically** at build time. All patches go through two Python-based helpers (never `sed`):
   - `replace_literal(file, search, replacement, required?)` — exact `str.replace()`; `required=1` aborts the build if the pattern is missing.
   - `replace_first_available(file, required, pattern1, replacement1, ...)` — forward-compatible: tries patterns in order, applies the first match.
   - Every patched file is re-verified with `node --check`. Originals are preserved as `.bak`.
5. **Emit `dist/`** with `start.sh` launcher, adapted `app.asar`, bundled Electron, Linux icons, and skill overrides from `packaging/skills-overrides/`.
6. **Optionally package** into portable `.tar.gz` with `build-metadata.env`.

### What the patches do (see `docs/ARCHITECTURE.md` for literal search/replace pairs)

- **Platform window chrome** — neutralize macOS `vibrancy`, `visualEffectState`, Windows `backgroundMaterial`, and transparent frameless windows. Swap the default transparent `BrowserWindow` background (`#00000000`) for opaque `#1e1e1e` so Linux doesn't render black voids where vibrancy used to sit.
- **File manager target** — upstream `fileManager` open target (`Xa`) only defines `darwin` and `win32`; the patch adds a `linux` entry using `xdg-open` and `electron.shell.openPath()`, with `path.dirname()` fallback to mirror macOS "reveal in Finder."
- **Skills path resolution** — the `yc()` function short-circuits to `app.getAppPath()/skills` on packaged builds; patch adds `existsSync` fallbacks through `app/skills → app/assets/skills → app/../skills → app/../assets/skills`.
- **Skills loader (deeplinks bundle)** — functions `Mk`, `Nk`, `Pk`, `tA` are patched to support bundled skill overrides with `sourceTag` tracking (`bundled`, `git`, `cache`, `bundled-override`), icon normalization to `data:` URIs, and reversed priority so bundled skills win over remote.
- **Launch flags** — `start.sh` injects `--disable-gpu-compositing` and Wayland/Ozone flags when appropriate.

### Runtime adaptations (not patches, replacements)

- **Webview HTTP proxy** (`webview-server.js`, port 5175) — local static host serving frontend UI so the main Electron process can load it despite `app.isPackaged=false` quirks and macOS-sandbox-oriented CORS/CSP.
- **App server (LSP over WebSockets)** — macOS ships a native Rust `codex` binary; on Linux `start.sh` executes the open-source `@openai/codex` npm package instead, bridging stdio and WebSocket ports.

### Versioning and release flow

Two independent version sources, centralized by `resolve_release_version()` in `build.sh`:

| Context | Version source | Example |
|---------|----------------|---------|
| `v*` tag push | `RELEASE_TAG` minus `v` prefix | `v0.2.0` → `0.2.0` |
| CI smoke (no tag) | Upstream DMG `package.json` | `26.309.31024` |

`UPSTREAM_VERSION` is always preserved in `build-metadata.env` for traceability. The resolved version drives every filename (`codex-desktop-native-<version>-linux-portable-x64.tar.gz`, `-archlinux-x86_64.pkg.tar.zst`, `-debian-amd64.deb`) and both `pkgver` (Arch) and `Version` (Debian).

`scripts/build-arch-package.sh` resolves `pkgver` with priority: `--pkgver` CLI arg → `RELEASE_VERSION` → `UPSTREAM_VERSION` → release label with `v` stripped.

### CI/CD contract

Two workflows under `.github/workflows/`:

- `ci.yml` — runs on PRs, pushes to `main`, manual dispatch. Lints workflows (actionlint), runs `pnpm run verify`, runs shellcheck, builds the portable artifact on non-PR events, verifies it under `xvfb-run`, then repeats the smoke test after Arch packaging (`archlinux` container + `pacman -U`) and Debian packaging (Ubuntu runner + `dpkg -i`).
- `release.yml` — runs on `v*` tags. Same build + smoke sequence, then generates release notes, validates asset contract, and creates/updates the GitHub Release.

Pipeline contract is deliberately encoded in shell helpers (`scripts/ci-lib.sh`, `scripts/verify-*.sh`) — never reimplement archive naming or smoke logic inside YAML. Node is pinned to 24 in CI; pnpm is activated via `corepack` through `scripts/enable-pnpm.sh` using the `packageManager` field in `codex-linux-build/package.json`.

External failures (OpenAI CDN, GitHub outages, package-mirror errors) are retriable infrastructure failures, not regressions.

## Conventions

- **Shell is primary.** Use `#!/usr/bin/env bash`, `set -euo pipefail`, quoted variables, four-space indent. Kebab-case script filenames (`verify-release-assets.sh`). `shellcheck` clean; `actionlint` clean for workflow YAML.
- **Treat as generated** and do not hand-edit: `codex-linux-build/dist/`, `codex-linux-build/artifacts/`, `codex-linux-build/native-rebuild/`, `codex_extracted/`.
- **Commits follow Conventional Commits with scopes**: `feat(ci): …`, `fix(build): …`, `refactor(ci): …`, `docs(readme): …`. Imperative, concise subjects.
- **PRs should describe the Linux packaging impact**, list the local commands run, and attach smoke-test evidence for packaging/launcher changes.
- **Patches must use `replace_literal` / `replace_first_available`**, never `sed`. Every new patch needs a `required` flag decision and a post-patch `node --check`.
