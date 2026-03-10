<div align="center">
  <img src="assets/codex-logo.png" alt="OpenAI Codex Logo" width="128" height="128" />
  <h1>OpenAI Codex Desktop for Linux</h1>
  <p><b>A fully automated build pipeline to bring the official macOS Codex app natively to Linux.</b></p>

  [![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
  [![Platform: Arch Linux (Tested)](https://img.shields.io/badge/Platform-Arch_Linux%20(CachyOS)-1793d1?logo=arch-linux)](https://cachyos.org/)
  [![Framework: Electron](https://img.shields.io/badge/Framework-Electron-47848F?logo=electron)](https://www.electronjs.org/)

</div>

---

## 🌟 What is this?

OpenAI released a dedicated Codex Desktop application exclusive to macOS. This project provides a fully automated pipeline that downloads the official macOS `.dmg` image, unpacks it, strips out Apple-specific binaries, recompiles everything for Linux `x64`, and patches graphical bugs to deliver a native, fully-functional experience on Linux.

> **Tested and verified on CachyOS (Arch-based) under Wayland & X11.**

---

## ✨ Features

- **End-to-End Automation:** A single `./build.sh` script does everything from downloading the `.dmg` to creating your desktop launcher.
- **Native Wayland/X11 Support:** Fully integrates with Ozone-platform on Linux.
- **Fixed Graphics:** Fully resolves macOS-specific `vibrancy` UI bugs that cause invisible or fully transparent windows on Linux compositors.
- **Background LSP integration:** Seamlessly bridges the local `app-server` using the open-source `@openai/codex` CLI (replacing the missing Linux binary).

## 🚀 Getting Started

### 1. Prerequisites
Ensure you have the following packages installed on your Linux machine:
* `node` (Node.js LTS), `npm`, `npx`
* `python3` (required for `node-gyp` builds)
* `7z` (p7zip - for extracting the Apple DMG)
* `wget`
* Base build tools (`base-devel` on Arch, `build-essential` on Debian/Ubuntu)

### 2. Build

Clone this repository and run the build script. It will automatically download the official DMG image right from OpenAI's servers and compile the native modules.

```bash
git clone https://github.com/mazixs/codex-desktop.git
cd codex-desktop/codex-linux-build
./build.sh
```

### 3. Launch

To start the app:

```bash
./start.sh
```

A handy `.desktop` application shortcut is automatically placed in your `~/.local/share/applications/` directory so you can launch Codex right from your app launcher!

## 🛑 Uninstallation

If you wish to remove Codex from your system entirely, run the following commands to delete the desktop entry, configuration, and build folders:

```bash
# Remove Desktop Launcher
rm ~/.local/share/applications/codex-desktop.desktop

# Remove Codex application data/configuration
rm -rf ~/.config/codex

# (Optional) Delete the repository folder
cd ..
rm -rf codex-desktop
```

---

## 🛠️ How It Works (Briefly)

The macOS binary isn't natively compatible with Linux. Here's a quick rundown of what the build pipeline achieves:

* **Rebuilding Native Modules:** Automatically replaces the bundled macOS ARM64 `node-pty` and `better-sqlite3` packages with freshly compiled Linux versions using `@electron/rebuild`.
* **Fixing Graphics:** macOS features native transparent window layers ("vibrancy"). On Linux compositors, this makes windows completely invisible. The script patches the core Electron `main.js` to enforce solid colors (Black/White based on your theme) and injects GPU compositing fixes.
* **Architecture Detoxing:** Removes macOS-exclusive features that crash Electron on Linux (like the `sparkle` auto-updater and Touch Bar APIs).

> 🧠 **Want to dive deeper?** Check out the full technical documentation in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the step-by-step reverse engineering log in [docs/TECHNICAL_DETAILS.md](docs/TECHNICAL_DETAILS.md).

---

## 🚑 Troubleshooting

**1. The App Window is Completely Black or Transparent**  
If you still experience issues under Wayland or NVIDIA proprietary drivers, launch the app directly with terminal overriding flags:
```bash
# Force X11 fallback (if Wayland is failing)
./start.sh --ozone-platform=x11

# Disable GPU acceleration completely
./start.sh --disable-gpu
```

**2. Port `5175` is already in use (`EADDRINUSE`)**  
The underlying Node.js local Webview server might have failed to terminate. The `start.sh` script automatically attempts to kill hanging ports using `fuser`, but if the issue persists, kill it manually:
```bash
fuser -k 5175/tcp
```

**3. Node-gyp or SQLite Compilation Fails**  
Make sure you have `python3` and `make` / `gcc` installed on your system.
* Arch Linux / CachyOS: `sudo pacman -S base-devel python`
* Ubuntu / Debian: `sudo apt install build-essential python3`

---

## 🤝 Contributions
Have improvements or fixes? Pull requests are always welcome!
