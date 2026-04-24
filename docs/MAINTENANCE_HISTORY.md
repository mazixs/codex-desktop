# Maintenance History

This document records recent repository maintenance work that changed the Linux adaptation layer.

## 2026-04-24

### Upstream Refresh

- Replaced the repository-local `Codex.dmg` after confirming the upstream artifact changed.
- Previous SHA-256: `65d3114117f1f03157e2968358e7c1bbaca48f3fe4a9bc9b71fc6f719e9702eb`
- New SHA-256: `590b5b986c26c10efa82d605b677eea0fc6142ed61b51c4fe91a4be8b09c1936`

### Codex CLI Update

- Updated the Linux CLI dependency from `@openai/codex@0.122.0` to `@openai/codex@0.124.0`.
- Rebuilt and smoke-tested the application with the refreshed upstream DMG and CLI.

### Linux UI Patch Maintenance

- Updated the opaque background patch to follow the current minified color variable (`Sy`) used by the upstream bundle.
- Kept the transparent-window, vibrancy, and background-material patches in place for Linux-safe rendering.
- Reworked the native menu strategy for Linux:
  - removed the earlier Alt-reveal behavior
  - removed the per-window native menu with `removeMenu()`
  - patched the upstream application-menu refresh path to use `Menu.setApplicationMenu(null)` on Linux so the menu bar does not come back after startup

### Validation

- `./build.sh --clean`
- `./build.sh --package`
- `./start.sh`
- `pnpm run verify`

The current baseline is a launchable Linux build with opaque window backgrounds, a suppressed native menu bar, a working Linux file-manager target, and packaged portable/Arch/Debian outputs.
