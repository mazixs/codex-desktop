# Maintenance History

This document records recent repository maintenance work that changed the Linux adaptation layer.

## 2026-05-20

### Upstream Refresh

- Refreshed against the upstream DMG (Codex Desktop `26.513.31313`).
- DMG SHA-256: `6d440c7133771935c860a5546bcd603f8b9b65b37e9b82bdb0019d4fd0c85b6a`.
- Bumped Electron runtime from `42.0.1` to `42.2.0`.
- Bumped `@openai/codex` CLI from `0.131.0` to `0.132.0`.
  - CLI 0.131.0 introduced remote plugin catalog sync (`chatgpt.com/backend-api/plugins/featured`
    and `/ps/plugins/installed`) which was blocked by Cloudflare 403 challenge pages, causing
    the `@` mention menu to return empty results.
- Verified native modules rebuild successfully and all JS/CSS patches apply correctly.

### Browser Compatibility & Detection

- Patched the Chrome plugin scripts to support dynamic browser and profile detection on Linux.
- Added support for `google-chrome-stable` (often found on Arch Linux), Brave Browser (`brave-browser`), and Chromium (`chromium`) commands.
- Configured dynamic user profile resolution checking `.config/google-chrome`, `.config/BraveSoftware/Brave-Browser`, and `.config/chromium`.
- Enabled native messaging host registration across Google Chrome, Brave, and Chromium to make the browser extension work seamlessly.


### Validation

- `rm -rf codex_extracted`
- `./codex-linux-build/build.sh --clean`
- `pnpm run verify`
- `tests/build-smoke.sh`

## 2026-05-15

### Upstream Refresh

- Refreshed against the upstream DMG (Codex Desktop `26.513.20950`).
- DMG SHA-256: `5937a9b4df03f611767dfbe524aa697cb4ce26be59d218e89070a7197e9dae4d`.
- Bumped Electron runtime to `42.0.1`.
- Kept `@openai/codex` CLI at current npm latest `0.130.0`.
- Bumped `better-sqlite3` native build to `12.10.0` and added an Electron 42/V8 sandbox compatibility patch for the transient rebuild copy.

### Plugin Updates

- Updated bundled plugin copying for upstream's new plugin names: `browser`, `chrome`, and `latex`.
- Kept `computer-use` excluded because upstream still ships it as a macOS app bundle.
- Kept the Browser/Chrome `site_status` request compatible with Linux `node_repl` allowlisting by stripping request metadata params.

### Validation

- `rm -rf codex_extracted`
- `./codex-linux-build/build.sh --clean --skip-download --dmg Codex.dmg`
- `./tests/build-smoke.sh`

## 2026-05-08

### Upstream Refresh

- Refreshed against the upstream DMG (Codex Desktop `26.506.21252`).
- DMG SHA-256: `2afad650981161bb86fd815221cfe97644611912b77c3a9f2a3d743bbae315c9`.
- Bumped Electron runtime to `41.3.0`.
- Bumped `@openai/codex` CLI to `0.130.0`.
- Bumped `better-sqlite3` native build to `12.9.0`.

### Browser Use Updates

- Aligned the `site_status` request patch with the `node_repl` allowlist to ensure the Browser Use plugin continues to function correctly on Linux.

### Validation

- `rm -rf codex_extracted`
- `./build.sh --clean`
- `pnpm run verify`
- `tests/build-smoke.sh`

## 2026-05-03

### Upstream Refresh

- Refreshed against the upstream DMG dated 2026-05-01 (314 MB).
- Resolved upstream application version: `26.429.30905`.
- New hashed main entrypoint: `main-DlFGMsC6.js`.

### Patch Strategy Migration

Migrated the main-bundle patches from exact string matching to regex-based detection so they survive upstream minified-name drift:
- **Opaque background** — detects the transparent color variable, dark/light color variables, and the background-material function signature dynamically, then injects a Linux-specific opaque branch.
- **File manager** — detects the win32 `open` handler and appends a Linux `xdg-open` entry.
- **Application menu** — detects `Menu.setApplicationMenu(...)` calls and nullifies the menu on Linux.
- **RemoveMenu** — expands win32-only `removeMenu()` guards to include Linux.
- Non-critical editor/IDE patches remain optional (warn-only on mismatch).

### Browser Use Plugin Support

- Added copying of `plugins/openai-bundled` resources from the upstream DMG into the build output.
- Copies upstream bundled plugin resources into the Linux build; newer DMGs expose `browser`, `chrome`, and `latex`.
- The launcher (`start.sh`) exports `CODEX_ELECTRON_RESOURCES_PATH`, `CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH`, `CODEX_BROWSER_USE_NODE_PATH`, and `CODEX_NODE_REPL_PATH` with a fallback to the system `node` when the upstream Mach-O binaries cannot be used.
- Added a `node_repl` symlink fallback in the build output pointing to the system `node` when the upstream `node_repl` is not a Linux ELF executable.

### Browser Annotation Stabilization

- Patched `.vite/build/comment-preload.js` to use stored anchor geometry instead of live DOM lookup during screenshot mode.
- Patched the same bundle to render only the selected marker while in screenshot mode.

### Launcher Updates

- Reworked Wayland ozone platform selection:
  - Wayland session → native Wayland via `--ozone-platform=wayland` by default.
  - Respects user-supplied `--ozone-platform*` flags.
  - Users can still force XWayland with `--ozone-platform=x11` if needed.

### Smoke Test Expansion

- Added regression smoke tests covering:
  - Opaque background Linux branch
  - File manager Linux entry
  - Application menu nullification
  - Comment-preload screenshot patches
  - Browser Use plugin resource presence

### Validation

- `rm -rf codex_extracted`
- `./build.sh --clean`
- `pnpm run verify`
- `tests/build-smoke.sh`

## 2026-04-24

### Upstream Refresh

- Replaced the repository-local `Codex.dmg` after confirming the upstream artifact changed.
- Previous SHA-256: `65d3114117f1f03157e2968358e7c1bbaca48f3fe4a9bc9b71fc6f719e9702eb`
- New SHA-256: `590b5b986c26c10efa82d605b677eea0fc6142ed61b51c4fe91a4be8b09c1936`
- The refreshed upstream application version resolved to `26.422.21637` during packaging.
- The refreshed upstream bundles included new hashed entrypoints such as `main-DCRKtMoS.js` and `workspace-root-drop-handler-C1fc5j6q.js`.

### Codex CLI Update

- Updated the Linux CLI dependency from `@openai/codex@0.122.0` to `@openai/codex@0.124.0`.
- Rebuilt and smoke-tested the application with the refreshed upstream DMG and CLI.

### Linux UI Patch Maintenance

- Updated the opaque background patch to follow the current minified color variables used by recent upstream bundles (`Sy` previously, `XC` in the refreshed bundle).
- Kept the transparent-window, vibrancy, and background-material patches in place for Linux-safe rendering.
- Reworked the native menu strategy for Linux:
  - removed the earlier Alt-reveal behavior
  - removed the per-window native menu with `removeMenu()`
  - patched the upstream application-menu refresh path to use `Menu.setApplicationMenu(null)` on Linux so the menu bar does not come back after startup

### Skills And Patch Anchor Refresh

- Rebound required main-bundle patch anchors to the refreshed upstream symbol set.
- Rebound required skills-bundle patch anchors after the recommended-skills loader moved to new minified function names.
- Preserved the Linux-specific bundled-skill override behavior after the upstream `workspace-root-drop-handler` bundle changed structure.

### Build Cache Note

- A CI failure exposed that `./build.sh --clean` does not remove the `codex_extracted/` cache.
- Local verification against a stale extracted app can therefore miss upstream patch breakage.
- For upstream refresh work, force a fresh extraction by deleting `codex_extracted/` or building against a newly downloaded DMG path.

### Validation

- `rm -rf codex_extracted`
- `./build.sh --clean`
- `./build.sh --clean --package --dmg /tmp/Codex.dmg`
- `./build.sh --package`
- `./start.sh`
- `pnpm run verify`

The current baseline is a launchable Linux build with opaque window backgrounds, a suppressed native menu bar, a working Linux file-manager target, and packaged portable/Arch/Debian outputs.
