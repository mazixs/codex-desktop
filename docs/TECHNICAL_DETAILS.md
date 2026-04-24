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

* **The Bug:** macOS uses `vibrancy` and `backgroundMaterial` for frosted glass window effects. The default `backgroundColor` is set to `#00000000` (fully transparent) in a minified variable (`Sy`, `So`, `Hf`, etc. depending on upstream build), which is invisible behind vibrancy on macOS but renders as a transparent window on Linux.

* **The Fix (9 patches in main bundle):**
  1. `Sy=\`#00000000\`` / `So="#00000000"` / `Hf=\`#00000000\`` → opaque dark color — replace transparent window background with an opaque dark fallback. The variable name changes between upstream builds, but it is the default `backgroundColor` for all `BrowserWindow` instances.
  2. `transparent:!0` → `transparent:!1` — disable transparent frameless windows (2 hotkey overlay windows).
  3. `vibrancy:\`menu\`` → `vibrancy:null` — neutralize macOS vibrancy (3 window types: primary, secondary, HUD).
  4. `visualEffectState:\`active\`` → `visualEffectState:null` — neutralize macOS visual effect (HUD window).
  5. `backgroundMaterial:\`mica\`` → `backgroundMaterial:null` — neutralize Windows Mica acrylic.
  6. `backgroundMaterial:\`none\`` → `backgroundMaterial:null` — neutralize Windows opaque background material.
  7. Keep `autoHideMenuBar` Windows-only so Linux does not inherit Electron's `Alt`-to-show behavior.
  8. Extend `removeMenu()` from Windows to Linux for each `BrowserWindow`.
  9. Patch the global application-menu refresh path to call `Menu.setApplicationMenu(null)` on Linux, preventing the upstream menu manager from restoring `File/Edit/View/Window/Help` after startup.

* **Key functions patched:**
  - `ap({platform, appearance, opaqueWindowsEnabled, prefersDarkColors})` — returns `{backgroundColor, backgroundMaterial}` per window type. After patching, always returns `{backgroundColor: '#1e1e1e', backgroundMaterial: null}` on Linux.
  - `op({appearance, opaqueWindowsEnabled, platform})` — returns window chrome options (`vibrancy`, `transparent`, `titleBarStyle`). After patching, all macOS/Windows-specific properties are nullified.
  - The application-menu refresh path now keeps upstream behavior on macOS/Windows but uses `Menu.setApplicationMenu(null)` on Linux so the menu bar stays absent even after startup refreshes.

* **Launch flags:** `start.sh` injects `--disable-gpu-compositing` and Wayland Ozone platform flags when appropriate.

## 8. Recent Upstream Maintenance

The current maintenance baseline also includes:

* **Fresh upstream DMG refresh:** the repository-local `Codex.dmg` was replaced after confirming a SHA-256 change from `65d3114117f1f03157e2968358e7c1bbaca48f3fe4a9bc9b71fc6f719e9702eb` to `590b5b986c26c10efa82d605b677eea0fc6142ed61b51c4fe91a4be8b09c1936`.
* **New upstream app version:** the refreshed bundle packaged as `26.422.21637`, with new hashed bundle entrypoints including `main-DCRKtMoS.js` and `workspace-root-drop-handler-C1fc5j6q.js`.
* **CLI bump:** the bundled Linux launcher path now targets `@openai/codex@0.124.0`.
* **Patch validation:** the refreshed upstream bundle required new patch anchors in both the main bundle and the skills bundle, but the Linux opacity, file-manager, skill override, and menu patches still apply after rebinding.
* **Operational caveat:** `./build.sh --clean` removes build outputs but not `codex_extracted/`. When validating a new upstream DMG or a CI patch failure, delete `codex_extracted/` or build against a fresh DMG path to avoid false-local green runs on stale extracted sources.

## 7. File Manager Integration (Open Folder in Skills)

* **The Bug:** The upstream `fileManager` open target (`Xa`) only defines handlers for `darwin` (macOS `open -R`) and `win32` (Windows `explorer.exe` / `shell.showItemInFolder`). On Linux, the target has no platform entry, so it is excluded from the available targets list when `ls(process.platform)` filters by platform. Clicking "Open folder" in Skills silently fails because the `open-file` IPC handler cannot find a registered `fileManager` target.

* **The Fix:** A build-time patch adds a `linux` entry to the `fileManager` target:
  - **Detection:** Uses `B('xdg-open')` — the bundled `which.sync` wrapper — to locate `xdg-open` on the system.
  - **Open handler:** Uses Electron's `shell.openPath()` API. If the path points to a file, it resolves to the parent directory via `path.dirname()` before opening, matching the macOS/Windows "reveal in folder" behavior.
  - The patch is non-required (`replace_literal` without `required=1`), so if upstream changes the `Xa` definition, the build continues with a warning.
