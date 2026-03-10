# Technical Adaptation Log

This document records the exact reverse-engineering steps and workarounds implemented to transparently port the macOS version of OpenAI Codex Desktop to Linux.

## 1. Initial Analysis of `Codex.dmg`
* Mounted and extracted `Codex.dmg` using `7z`.
* Explored `/Contents/Resources/app.asar` and unpacked it using `npx asar extract`.
* Identified `package.json` configurations.
* Confirmed via `file` command that all pre-compiled native `.node` modules and CLI binaries inside the bundle were compiled strictly for macOS `Mach-O arm64` (Apple Silicon) or `x86_64`.
* Found that the UI was bundled using Vite, minified into `dist/.vite/build/main.js`.

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
* **The Bug:** macOS leverages `vibrancy` to blur backgrounds via the Compositor. Porting `transparent: true` to Linux (especially Wayland) without a compatible compositing backend results in "invisible" application windows.
* **The Fix:**
  1. Scrubbed `transparent:!0` to `transparent:!1` (false) and `vibrancy:` to `null`.
  2. Overriden Electron's minified background hex (`Z7` = `#00000000`) with dynamic theme parameters (`ure` = `#000000`, `dre` = `#f9f9f9`), forcing solid, opaque rendering.
  3. Wrapped the final execution in `start.sh` with GPU composition flags (`--disable-gpu-compositing`) and Wayland Ozone (`--enable-features=UseOzonePlatform --ozone-platform=wayland`).
