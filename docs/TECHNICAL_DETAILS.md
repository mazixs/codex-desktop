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
* **`better-sqlite3.node` & `node-pty.node`**: Hard-compiled for macOS. **Solution:** Script deletes the `.node` binaries in `node_modules`. Instead of fetching from unverified sources, the pipeline uses `@electron/rebuild` against the pinned upstream-compatible Electron headers (`electron@42.1.0`) to securely compile native versions of `better-sqlite3@12.10.0` and `node-pty@1.1.0` locally using `/usr/bin/gcc`.

## 3. The `codex` LSP CLI Replacement
* Opening `/Contents/Resources/bin/codex` revealed it was the Rust backend acting as the Language Server (LSP) and WebSocket communication handler.
* **Solution:** Analyzed the `package.json` logic and discovered the open-source npm equivalent: `@openai/codex`.
* In `start.sh`, we dynamically install the `@openai/codex` CLI and set the `CODEX_CLI_PATH` environment variable. Electron detects this path and spawns the node-based CLI server directly instead of looking for the missing Darwin binary.

## 4. Product Packaging and `isPackaged`
* Product artifacts pack the patched app back into `resources/app.asar` and launch a renamed Electron binary (`codex-desktop`) without passing an app directory. This keeps Electron on the packaged runtime branch (`app.isPackaged = true`).
* External runtime helpers under `resources/` include relocatable checksum files, and `node_repl.runtime.env` records the pinned primary-runtime version, source URL, source SHA256, and packaged SHA256.
* The old `electron dist/` flow is retained only as an unpacked development fallback. In that fallback, `webview-server.js` hosts `dist/webview` on `127.0.0.1:5175` to mimic the asset server expected by unpacked code.
* The unpacked fallback is not a plugin validation target. It runs with `app.isPackaged = false` and can expose development-only state, dev/test bundled plugin catalog behavior, and stale `CODEX_*` runtime paths inherited from an already installed Codex Desktop process.
* Product `start.sh` now derives Browser Use and Chrome runtime paths from the active artifact's `resources/` directory by default. This prevents an older `/opt/codex-desktop/dist/node_repl` or system `node` override from breaking the Browser Use plugin in a freshly packaged app. Maintainers can opt back into inherited paths only with `CODEX_DESKTOP_RESPECT_RUNTIME_ENV=1`.

## 5. Main Process Patching (`main.js`)
Minified JavaScript requires exact structural `sed` replacements:
* **Filesystem Paths:** `Library/Application Support/Codex` is macOS-only. Patched to use `.config/codex` (XDG Base Directory).
* **Darwin Checks:** `process.platform === 'darwin'` causes missing `type` crashes in window panels. Handled by nullifying the check.
* **Window Dimensions:** Removed constraints preventing proper resizing of frameless windows.

## 6. Resolving Linux Composition (Transparency Fix)

* **The Bug:** macOS uses `vibrancy` and `backgroundMaterial` for frosted glass window effects. The default `backgroundColor` is set to `#00000000` (fully transparent) in a minified variable (`Sy`, `So`, `Hf`, etc. depending on upstream build), which is invisible behind vibrancy on macOS but renders as a transparent window on Linux.

* **The Fix (9 patches in main bundle):**
  1. Inject a Linux branch into the background helper so non-transparent Linux windows use the upstream theme colors (`prefersDarkColors ? dark : light`) with `backgroundMaterial:null`; the transparent fallback stays intact for window types that intentionally use it.
  2. `transparent:!0` → `transparent:!1` — disable transparent frameless windows (2 hotkey overlay windows).
  3. `vibrancy:\`menu\`` → `vibrancy:null` — neutralize macOS vibrancy (3 window types: primary, secondary, HUD).
  4. `visualEffectState:\`active\`` → `visualEffectState:null` — neutralize macOS visual effect (HUD window).
  5. `backgroundMaterial:\`mica\`` → `backgroundMaterial:null` — neutralize Windows Mica acrylic.
  6. `backgroundMaterial:\`none\`` → `backgroundMaterial:null` — neutralize Windows opaque background material.
  7. Keep `autoHideMenuBar` Windows-only so Linux product windows keep the upstream native menu visible.
  8. Preserve the upstream application menu on Linux instead of extending `removeMenu()` or forcing `Menu.setApplicationMenu(null)`. The older dev-runtime workaround made File/Edit/View/Window/Help inert in product mode.

* **Key functions patched:**
  - `ap({platform, appearance, opaqueWindowsEnabled, prefersDarkColors})` — returns `{backgroundColor, backgroundMaterial}` per window type. After patching, non-transparent Linux windows return `{backgroundColor: prefersDarkColors ? dark : light, backgroundMaterial: null}` so light theme keeps its upstream light background.
  - `op({appearance, opaqueWindowsEnabled, platform})` — returns window chrome options (`vibrancy`, `transparent`, `titleBarStyle`). After patching, all macOS/Windows-specific properties are nullified.
  - The application-menu refresh path is left intact on Linux so the product native menu remains functional.

* **Launch flags:** `start.sh` injects `--disable-gpu-compositing` and Wayland Ozone platform flags when appropriate.

## 8. Recent Upstream Maintenance

The current maintenance baseline also includes:

* **Fresh upstream DMG refresh:** the repository-local `Codex.dmg` was replaced after confirming a new upstream release (SHA-256 `23ead69adccc6910912cef1e0c73fb7667e4d07fcce7cfcad45eae54d38ad897`).
* **New upstream app version:** the refreshed bundle packaged as `26.602.40724`.
* **CLI bump:** the bundled Linux launcher path now targets `@openai/codex@0.137.0`.
* **Patch validation:** the refreshed upstream bundle required new patch anchors in both the main bundle and the skills bundle, but the Linux opacity, file-manager, skill override, and menu patches still apply after rebinding.
* **Operational caveat:** `./build.sh --clean` removes build outputs but not `codex_extracted/`. When validating a new upstream DMG or a CI patch failure, delete `codex_extracted/` or build against a fresh DMG path to avoid false-local green runs on stale extracted sources.

## 7. File Manager Integration (Open Folder in Skills)

* **The Bug:** The upstream `fileManager` open target (`Xa`) only defines handlers for `darwin` (macOS `open -R`) and `win32` (Windows `explorer.exe` / `shell.showItemInFolder`). On Linux, the target has no platform entry, so it is excluded from the available targets list when `ls(process.platform)` filters by platform. Clicking "Open folder" in Skills silently fails because the `open-file` IPC handler cannot find a registered `fileManager` target.

* **The Fix:** A build-time patch adds a `linux` entry to the `fileManager` target:
  - **Detection:** Uses `B('xdg-open')` — the bundled `which.sync` wrapper — to locate `xdg-open` on the system.
  - **Open handler:** Uses Electron's `shell.openPath()` API. If the path points to a file, it resolves to the parent directory via `path.dirname()` before opening, matching the macOS/Windows "reveal in folder" behavior.
  - The patch is non-required (`replace_literal` without `required=1`), so if upstream changes the `Xa` definition, the build continues with a warning.

## 9. Dynamic Browser Detection & Profile Matching on Linux

* **The Problem:** The upstream Google Chrome plugin expects `google-chrome` or `chrome` to be available in PATH. However, on many Linux distributions (such as Arch Linux), the binary is named `google-chrome-stable`. Additionally, if Google Chrome is not found, the plugin attempts to fall back to downloading Playwright's bundled Chromium, which is undesired.
* **The Fix:**
  - **Browser detection (`installed-browsers.js`):** Expanded `KNOWN_BROWSERS` configuration to check `google-chrome-stable` before `google-chrome`. Added support for Brave Browser (`brave-browser`, `brave`) and Chromium (`chromium-browser`, `chromium`) as alternative options.
  - **Launcher (`open-chrome-window.js`):** Modified the browser launch command to dynamically check for the first available binary (`google-chrome-stable`, `google-chrome`, `brave-browser`, etc.) in the PATH.
  - **Profile paths (`open-chrome-window.js` & `check-extension-installed.js`):** Patched the user data directory resolver to dynamically check `.config/google-chrome`, `.config/BraveSoftware/Brave-Browser`, and `.config/chromium` based on which one actually exists.
  - **Native Messaging (`installManifest.mjs`):** Patched the extension native messaging host installer to write the JSON manifest to all three configuration folders, enabling the extension to work seamlessly regardless of whether the user runs Google Chrome, Brave, or Chromium.
