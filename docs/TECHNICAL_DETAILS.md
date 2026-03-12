# Technical Adaptation Log

This document records the exact reverse-engineering steps and workarounds implemented to transparently port the macOS version of OpenAI Codex Desktop to Linux.

## 1. Initial Analysis of `Codex.dmg`
* Mounted and extracted `Codex.dmg` using `7z`.
* Explored `/Contents/Resources/app.asar` and unpacked it using `npx asar extract`.
* Identified `package.json` configurations.
* Confirmed via `file` command that all pre-compiled native `.node` modules and CLI binaries inside the bundle were compiled strictly for macOS `Mach-O arm64` (Apple Silicon) or `x86_64`.
* Found that the UI was bundled using Vite, with entry point at `.vite/build/bootstrap.js` and hashed bundles (`main-*.js`, `deeplinks-*.js`).

## 2. Dealing with Native Modules
Native Node.js extensions specific to the macOS build fail to load under Linux's dynamic linker (glibc).
* **`sparkle.node`**: A wrapper for the Sparkle macOS auto-updater. It has no Linux equivalent. **Solution:** Completely deleted. We patch Electron to ignore `require('electron-squirrel-startup')` and Sparkle components.
* **`better-sqlite3.node` & `node-pty.node`**: Hard-compiled for macOS. **Solution:** Script deletes the `.node` binaries in `node_modules`. Instead of fetching from unverified sources, the pipeline uses `@electron/rebuild` against `electron@40.0.0` headers to securely compile native versions of `better-sqlite3@12.5.0` and `node-pty@1.1.0` locally using `/usr/bin/gcc`.

## 3. The `codex` LSP CLI Replacement
* Opening `/Contents/Resources/bin/codex` revealed it was the Rust backend acting as the Language Server (LSP) and WebSocket communication handler.
* **Solution:** Analyzed the `package.json` logic and discovered the open-source npm equivalent: `@openai/codex`.
* In `start.sh`, we dynamically install the `@openai/codex` CLI and set the `CODEX_CLI_PATH` environment variable. Electron detects this path and spawns the node-based CLI server directly instead of looking for the missing Darwin binary.

## 4. Bypassing Application Sandboxing and `isPackaged`
* When running unpacked code (`isPackaged = false`), Electron expects a Vite development server (localhost:5175). Since we pull static bundled assets (`dist/webview`), Electron fails to `loadURL()` due to missing protocols and strict Cross-Origin Resource Sharing (CORS) rules.
* **Solution:** We introduced a local Node.js HTTP server (`webview-server.js`). It hosts the `dist/webview` directory on `127.0.0.1:5175`, effectively mimicking Vite's production/dev behavior organically. 
* To prevent `EADDRINUSE` port collision loops, `start.sh` uses `fuser -k 5175/tcp` before launching.

## 5. Main Process Patching (`main.js`)
Minified JavaScript requires exact structural `sed` replacements:
* **Filesystem Paths:** `Library/Application Support/Codex` is macOS-only. Patched to use `.config/codex` (XDG Base Directory).
* **Darwin Checks:** `process.platform === 'darwin'` causes missing `type` crashes in window panels. Handled by nullifying the check.
* **Window Dimensions:** Removed constraints preventing proper resizing of frameless windows.

## 6. Resolving Linux Composition (Transparency Fix)

* **The Bug:** macOS uses `vibrancy` and `backgroundMaterial` for frosted glass window effects. The default `backgroundColor` is set to `#00000000` (fully transparent) in the minified variable `Hf`, which is invisible behind vibrancy on macOS but renders as a completely transparent window on Linux.

* **The Fix (6 patches in main bundle):**
  1. `Hf=\`#00000000\`` → `Hf=\`#1e1e1e\`` — replace transparent background with opaque dark color. `Hf` is the default `backgroundColor` for all `BrowserWindow` instances. Related constants: `Uf=\`#000000\`` (dark theme), `Wf=\`#f9f9f9\`` (light theme).
  2. `transparent:!0` → `transparent:!1` — disable transparent frameless windows (2 hotkey overlay windows).
  3. `vibrancy:\`menu\`` → `vibrancy:null` — neutralize macOS vibrancy (3 window types: primary, secondary, HUD).
  4. `visualEffectState:\`active\`` → `visualEffectState:null` — neutralize macOS visual effect (HUD window).
  5. `backgroundMaterial:\`mica\`` → `backgroundMaterial:null` — neutralize Windows Mica acrylic.
  6. `backgroundMaterial:\`none\`` → `backgroundMaterial:null` — neutralize Windows opaque background material.

* **Key functions patched:**
  - `ap({platform, appearance, opaqueWindowsEnabled, prefersDarkColors})` — returns `{backgroundColor, backgroundMaterial}` per window type. After patching, always returns `{backgroundColor: '#1e1e1e', backgroundMaterial: null}` on Linux.
  - `op({appearance, opaqueWindowsEnabled, platform})` — returns window chrome options (`vibrancy`, `transparent`, `titleBarStyle`). After patching, all macOS/Windows-specific properties are nullified.

* **Launch flags:** `start.sh` injects `--disable-gpu-compositing` and Wayland Ozone platform flags when appropriate.
