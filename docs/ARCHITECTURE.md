# Codex for Linux Architecture

This document describes the technical implementation details of adapting the macOS-native OpenAI Codex Desktop application for Linux.

## 1. Native Dependencies Replacement

The original application (`app.asar`) is distributed with pre-compiled `.node` modules targeting Darwin (macOS) `arm64/x64`. 
The build script performs a complete extraction, removes these binaries, and dynamically recompiles them for Linux x64:

* `better-sqlite3`: Removed and re-installed via npm (`v12.10.0`), then compiled via `@electron/rebuild`.
* `node-pty`: Replaced the macOS PTY bridge with a native Linux PTY implementation (`v1.1.0`), built against Electron headers.
* `sparkle`: The auto-updates framework is entirely macOS-specific and deleted outright from the build.

## 2. Electron Main Process Patches (Hashed Bundles)

The upstream application uses Vite's code-splitting with content-hashed filenames. The entry point is `.vite/build/bootstrap.js`, which loads the main bundle (`main-<hash>.js`) and deeplinks bundle (`deeplinks-<hash>.js`).

The build script (`codex-linux-build/build.sh`) dynamically discovers these bundles at build time and applies patches using the `replace_literal` helper (Python-based exact string replacement, not sed). Each patch is verified with `node --check` after application.

### Patching Infrastructure

* **`replace_literal(file, search, replacement, required?)`** — exact string replacement via Python `str.replace()`. Replaces all occurrences. The `required` flag (default 0) causes a build failure if the pattern is not found.
* **`replace_first_available(file, required, pattern1, replacement1, ...)`** — tries patterns in order, applies the first match. Used for forward-compatible patching across upstream versions.
* All patches are applied to backup copies; originals are preserved as `.bak`.

### A. Platform Window Properties (main bundle)

macOS relies on native compositor features (`vibrancy`, `backgroundMaterial`) for its frosted glass UI. On Linux these have no effect or cause rendering failures.

| Patch | Occurrences | Purpose |
|-------|-------------|--------|
| Linux branch in the background helper | 1 | Return an opaque Linux background using upstream dark/light colors (`prefersDarkColors ? dark : light`) while preserving the transparent fallback for window types that intentionally use it. |
| `transparent:!0` → `transparent:!1` | 2 | Disable transparent frameless windows (hotkey overlay windows). |
| `vibrancy:\`menu\`` → `vibrancy:null` | 3 | Neutralize macOS vibrancy effect for primary, secondary, and HUD windows. |
| `visualEffectState:\`active\`` → `visualEffectState:null` | 1 | Neutralize macOS visual effect on HUD window. |
| `backgroundMaterial:\`mica\`` → `backgroundMaterial:null` | 1 | Neutralize Windows Mica acrylic material. |
| `backgroundMaterial:\`none\`` → `backgroundMaterial:null` | 1 | Neutralize Windows background material for opaque mode. |
| `autoHideMenuBar` Windows guard → Windows only | 1 | Avoid Electron's Alt-revealed fallback menubar on Linux. |
| Linux `setMenuBarVisibility(false)` | 2 | Hide the duplicate native Electron menubar on window creation and after application-menu refreshes while keeping `Menu.getApplicationMenu()` available for in-app menu buttons. |

The `ap()` function in the main bundle returns `{backgroundColor, backgroundMaterial}` per window type. The `op()` function returns platform-specific window chrome options (`vibrancy`, `transparent`, `titleBarStyle`, etc.). Both are patched to produce Linux-safe values. The product Linux build now preserves the upstream application menu instead of nullifying `Menu.setApplicationMenu(...)`; the old menu-suppression patch was useful for the unpacked developer runtime but makes the product File/Edit/View/Window/Help menu inert. On Linux the native Electron window menubar is hidden, while the renderer-owned File/Edit/View/Window/Help controls still popup submenus through `Menu.getApplicationMenu()`.

### B. File Manager Target for Linux (main bundle)

The upstream `fileManager` open target (used by the "Open folder" button in Skills and elsewhere) only defines `darwin` and `win32` platform entries. On Linux the target is never registered, so clicking "Open folder" silently fails.

The patch adds a `linux` entry to the `fileManager` target definition (`Xa`):

| Property | Value | Purpose |
|----------|-------|---------|
| `label` | `File Manager` | Display name in the UI |
| `detect` | `B('xdg-open')` | Uses the bundled `which.sync` wrapper to locate `xdg-open` |
| `args` | `e => [e]` | Pass path directly as argument |
| `open` | Custom async handler | Uses `electron.shell.openPath()` after resolving file paths to their parent directory |

If the path points to a file, the handler navigates to its parent directory via `path.dirname()`. This mirrors the macOS behavior of `open -R` (reveal in Finder) and the Windows behavior of `shell.showItemInFolder()`.

### C. Skills Path Resolution (main bundle)

The `yc()` function resolves the skills directory. The upstream version short-circuits to `app.getAppPath()/skills` when `isPackaged` is true, skipping existence checks. The patch adds fallback paths with `existsSync` checks:

```
app/skills → app/assets/skills → app/../skills → app/../assets/skills
```

### D. Skills Loader & Resolver (deeplinks bundle)

Four functions in the deeplinks bundle are patched to support bundled skill overrides:

* **`Mk` (recommended skills loader)** — adds bundled skill override support with `mergeRecommendedSkillLists` and `logBundledSkillOverrides` helpers.
* **`Nk` (skill enumerator)** — adds `sourceTag` parameter for tracking skill origin (`bundled`, `git`, `cache`, `bundled-override`).
* **`Pk` (individual skill loader)** — adds `sourceTag` propagation, icon normalization via `normalizeSkillIconUrl` (converts local file paths to `data:` URIs).
* **`tA` (skill resolver)** — reverses priority to check bundled skills before remote, enabling offline skill overrides.

### E. Launch Script Flags

The `start.sh` wrapper injects GPU composition flags (`--disable-gpu-compositing`) and Wayland/Ozone flags when appropriate.

## 3. Product Runtime Layout

Release artifacts run as a packaged Electron application. The patched upstream app is packed back into `node_modules/electron/dist/resources/app.asar`, native modules are unpacked into `app.asar.unpacked`, and external runtime resources such as bundled plugins, `codex`, `node`, and `node_repl` live next to the archive under `resources/`. Runtime checksums are stored with basename-relative paths so portable archives remain relocatable after extraction.

This repository intentionally moved away from using the unpacked Codex developer runtime as the release target. In `electron dist/` mode Electron reports `app.isPackaged = false`, the app can enter development-only branches, and bundled plugins may reconcile against dev/test catalog state or stale environment overrides. That instability is especially visible in Browser Use, where the selected `codex` CLI resource, `node`, `node_repl`, plugin marketplace, and trusted browser-client hash must match the packaged resources.

The product launcher therefore executes `node_modules/electron/dist/codex-desktop` without an app-directory argument. It also sets `CODEX_ELECTRON_RESOURCES_PATH`, `CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH`, `CODEX_BROWSER_USE_NODE_PATH`, `NODE_REPL_NODE_PATH`, and `CODEX_NODE_REPL_PATH` from the active product `resources/` directory by default. The packaged `resources/codex` symlink is part of the Electron resources contract, while `start.sh` still resolves `CODEX_CLI_PATH` from the installed `@openai/codex` CLI. The external Chrome plugin is added to the bundled marketplace only when a real Linux native messaging host exists at `plugins/chrome/extension-host/linux/x64/extension-host`; macOS-only `extension-host/macos/...` payloads are copied for audit but not auto-installed on Linux. Explicit runtime overrides are possible only by setting `CODEX_DESKTOP_RESPECT_RUNTIME_ENV=1`, which is intended for debugging rather than release packaging.

The `webview-server.js` proxy remains only for the unpacked development fallback. Product launches do not pass `dist/` to Electron and therefore keep `app.isPackaged = true`.

## 4. App Server (Language Server Protocol)

The Codex application relies on a background application server (LSP over WebSockets) to handle code completion, logic analysis, and telemetry. 
* macOS includes a native Rust binary (`codex`) embedded in `Contents/Resources/bin`.
* On Linux, the shell wrapper (`start.sh`) detects and executes the official open-source `@openai/codex` CLI package (installed via npm) instead of the missing binary. Standard I/O and WebSocket ports are bridged automatically to link the Electron frontend with the local node-based language server.
