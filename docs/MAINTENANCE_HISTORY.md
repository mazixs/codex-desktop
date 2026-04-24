# Maintenance History

This document records recent repository maintenance work that changed the Linux adaptation layer.

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
