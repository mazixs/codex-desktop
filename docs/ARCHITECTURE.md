# Codex for Linux Architecture

This document describes the technical implementation details of adapting the macOS-native OpenAI Codex Desktop application for Linux.

## 1. Native Dependencies Replacement

The original application (`app.asar`) is distributed with pre-compiled `.node` modules targeting Darwin (macOS) `arm64/x64`. 
The build script performs a complete extraction, removes these binaries, and dynamically recompiles them for Linux x64:

* `better-sqlite3`: Removed and re-installed via npm (`v12.5.0`), then compiled via `@electron/rebuild`.
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
| `Hf=\`#00000000\`` → `Hf=\`#1e1e1e\`` | 1 | Replace fully-transparent background color with opaque dark. `Hf` is the default `backgroundColor` passed to every `BrowserWindow`; on macOS it is invisible behind vibrancy, on Linux it becomes the visible background. |
| `transparent:!0` → `transparent:!1` | 2 | Disable transparent frameless windows (hotkey overlay windows). |
| `vibrancy:\`menu\`` → `vibrancy:null` | 3 | Neutralize macOS vibrancy effect for primary, secondary, and HUD windows. |
| `visualEffectState:\`active\`` → `visualEffectState:null` | 1 | Neutralize macOS visual effect on HUD window. |
| `backgroundMaterial:\`mica\`` → `backgroundMaterial:null` | 1 | Neutralize Windows Mica acrylic material. |
| `backgroundMaterial:\`none\`` → `backgroundMaterial:null` | 1 | Neutralize Windows background material for opaque mode. |

The `ap()` function in the main bundle returns `{backgroundColor, backgroundMaterial}` per window type. The `op()` function returns platform-specific window chrome options (`vibrancy`, `transparent`, `titleBarStyle`, etc.). Both are patched to produce Linux-safe values.

### B. Skills Path Resolution (main bundle)

The `yc()` function resolves the skills directory. The upstream version short-circuits to `app.getAppPath()/skills` when `isPackaged` is true, skipping existence checks. The patch adds fallback paths with `existsSync` checks:

```
app/skills → app/assets/skills → app/../skills → app/../assets/skills
```

### C. Skills Loader & Resolver (deeplinks bundle)

Four functions in the deeplinks bundle are patched to support bundled skill overrides:

* **`Mk` (recommended skills loader)** — adds bundled skill override support with `mergeRecommendedSkillLists` and `logBundledSkillOverrides` helpers.
* **`Nk` (skill enumerator)** — adds `sourceTag` parameter for tracking skill origin (`bundled`, `git`, `cache`, `bundled-override`).
* **`Pk` (individual skill loader)** — adds `sourceTag` propagation, icon normalization via `normalizeSkillIconUrl` (converts local file paths to `data:` URIs).
* **`tA` (skill resolver)** — reverses priority to check bundled skills before remote, enabling offline skill overrides.

### D. Launch Script Flags

The `start.sh` wrapper injects GPU composition flags (`--disable-gpu-compositing`) and Wayland/Ozone flags when appropriate.

## 3. Webview HTTP Proxy

To bypass `app.isPackaged = false` limitations and strict CORS/CSP parameters designed around macOS sandbox environments, the build script generates a secondary lightweight Node.js Server (`webview-server.js`). 
This server acts as a local static host on port `5175`, serving the frontend UI assets locally, which the main Electron process then loads.

## 4. App Server (Language Server Protocol)

The Codex application relies on a background application server (LSP over WebSockets) to handle code completion, logic analysis, and telemetry. 
* macOS includes a native Rust binary (`codex`) embedded in `Contents/Resources/bin`.
* On Linux, the shell wrapper (`start.sh`) detects and executes the official open-source `@openai/codex` CLI package (installed via npm) instead of the missing binary. Standard I/O and WebSocket ports are bridged automatically to link the Electron frontend with the local node-based language server.
