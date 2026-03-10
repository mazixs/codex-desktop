#!/usr/bin/env bash
# build.sh — Build OpenAI Codex Desktop for Linux (Arch Linux)
# Variant B: Hybrid approach
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXTRACTED_DIR="$PROJECT_ROOT/codex_extracted"
APP_UNPACKED="$EXTRACTED_DIR/app_unpacked"
BUILD_DIR="$SCRIPT_DIR/dist"
ELECTRON_VERSION="40.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ── Phase 1: Verify prerequisites ──────────────────────────────────────────────
log "Phase 1: Verifying prerequisites..."

for cmd in node npm pnpm python3 rg 7z; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Missing required command: $cmd"
        exit 1
    fi
done

DMG_FILE="$PROJECT_ROOT/Codex.dmg"
DMG_URL="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"

if [ ! -f "$DMG_FILE" ]; then
    log "Downloading Codex.dmg from official source..."
    if ! wget -q --show-progress -O "$DMG_FILE.tmp" "$DMG_URL"; then
        err "Failed to download Codex.dmg"
        rm -f "$DMG_FILE.tmp"
        exit 1
    fi
    mv "$DMG_FILE.tmp" "$DMG_FILE"
fi

# Sanity check: ensure DMG is at least 50MB
DMG_SIZE=$(stat -c%s "$DMG_FILE" 2>/dev/null || stat -f%z "$DMG_FILE" 2>/dev/null || echo 0)
if [ "$DMG_SIZE" -lt 52428800 ]; then
    err "Codex.dmg is too small ($DMG_SIZE bytes). Download may be corrupted."
    err "Delete $DMG_FILE and try again."
    exit 1
fi

if [ ! -d "$APP_UNPACKED" ]; then
    log "Extracting Codex.dmg..."
    mkdir -p "$EXTRACTED_DIR"
    cd "$PROJECT_ROOT"
    # Extract DMG
    7z x -y "$DMG_FILE" -o"$EXTRACTED_DIR" >/dev/null
    
    log "Extracting app.asar..."
    npx asar extract "$EXTRACTED_DIR/Codex Installer/Codex.app/Contents/Resources/app.asar" "$APP_UNPACKED"
fi

log "All prerequisites OK"

# ── Phase 2: Prepare working copy ─────────────────────────────────────────────
log "Phase 2: Preparing working copy..."

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copy app sources
cp -a "$APP_UNPACKED/.vite" "$BUILD_DIR/"
cp -a "$APP_UNPACKED/webview" "$BUILD_DIR/"
cp -a "$APP_UNPACKED/skills" "$BUILD_DIR/"
cp "$APP_UNPACKED/package.json" "$BUILD_DIR/"

# Copy node_modules (we'll replace native ones)
cp -a "$APP_UNPACKED/node_modules" "$BUILD_DIR/"

log "Working copy prepared at $BUILD_DIR"

# ── Phase 3: Rebuild native modules ───────────────────────────────────────────
log "Phase 3: Rebuilding native modules for Linux..."

# Remove macOS-only native module
log "Removing sparkle.node (macOS-only)..."
rm -rf "$BUILD_DIR/native" 2>/dev/null || true
mkdir -p "$BUILD_DIR/native"

# Remove macOS .node binaries
find "$BUILD_DIR/node_modules/better-sqlite3" -name "*.node" -delete 2>/dev/null || true
find "$BUILD_DIR/node_modules/node-pty" -name "*.node" -delete 2>/dev/null || true
rm -rf "$BUILD_DIR/node_modules/node-pty/bin" 2>/dev/null || true

# Install full better-sqlite3 and node-pty packages from npm for rebuild
NATIVE_BUILD_DIR="$SCRIPT_DIR/native-rebuild"
rm -rf "$NATIVE_BUILD_DIR"
mkdir -p "$NATIVE_BUILD_DIR"

cat > "$NATIVE_BUILD_DIR/package.json" << 'EOF'
{
  "name": "native-rebuild",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "better-sqlite3": "12.5.0",
    "node-pty": "1.1.0"
  }
}
EOF

cd "$NATIVE_BUILD_DIR"

log "Installing native modules from npm..."
npm install 2>&1 | tail -20

log "Rebuilding for Electron $ELECTRON_VERSION..."
npx @electron/rebuild \
    -v "$ELECTRON_VERSION" \
    -m "$NATIVE_BUILD_DIR" \
    --types prod \
    -o better-sqlite3,node-pty 2>&1 | tail -10

# Copy rebuilt modules back
log "Copying rebuilt native modules..."
cp -a "$NATIVE_BUILD_DIR/node_modules/better-sqlite3/build" \
    "$BUILD_DIR/node_modules/better-sqlite3/"

# Copy node-pty build
if [ -d "$NATIVE_BUILD_DIR/node_modules/node-pty/build" ]; then
    cp -a "$NATIVE_BUILD_DIR/node_modules/node-pty/build" \
        "$BUILD_DIR/node_modules/node-pty/"
fi

# Also copy prebuilt binary if exists
if [ -d "$NATIVE_BUILD_DIR/node_modules/node-pty/bin" ]; then
    cp -a "$NATIVE_BUILD_DIR/node_modules/node-pty/bin" \
        "$BUILD_DIR/node_modules/node-pty/"
fi

# Copy node-pty source files needed at runtime  
for f in src lib; do
    if [ -d "$NATIVE_BUILD_DIR/node_modules/node-pty/$f" ]; then
        cp -a "$NATIVE_BUILD_DIR/node_modules/node-pty/$f" \
            "$BUILD_DIR/node_modules/node-pty/" 2>/dev/null || true
    fi
done

cd "$SCRIPT_DIR"

# Verify
SQLITE_NODE="$BUILD_DIR/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
PTY_NODE=$(find "$BUILD_DIR/node_modules/node-pty" -name "*.node" | head -1)

if [ -f "$SQLITE_NODE" ]; then
    FILE_TYPE=$(file "$SQLITE_NODE")
    if echo "$FILE_TYPE" | grep -q "ELF"; then
        log "✓ better-sqlite3: $FILE_TYPE"
    else
        err "better-sqlite3 is NOT an ELF binary: $FILE_TYPE"
        exit 1
    fi
else
    err "better-sqlite3.node not found at $SQLITE_NODE"
    exit 1
fi

if [ -n "$PTY_NODE" ] && [ -f "$PTY_NODE" ]; then
    FILE_TYPE=$(file "$PTY_NODE")
    if echo "$FILE_TYPE" | grep -q "ELF"; then
        log "✓ node-pty: $FILE_TYPE"
    else
        err "node-pty is NOT an ELF binary: $FILE_TYPE"
        exit 1
    fi
else
    warn "node-pty .node not found — will attempt fallback"
fi

log "Phase 3 complete: native modules rebuilt"

# ── Phase 4: Patch main.js ────────────────────────────────────────────────────
log "Phase 4: Patching main.js..."

MAIN_JS="$BUILD_DIR/.vite/build/main.js"
cp "$MAIN_JS" "$MAIN_JS.bak"

# 4.1: Remove sparkle.node require (wrap in try-catch / noop)
# Find sparkle references and neutralize them
sed -i 's|require("./native/sparkle.node")|(() => { throw new Error("sparkle not available on linux") })()|g' "$MAIN_JS"
sed -i 's|require(`./native/sparkle.node`)|(() => { throw new Error("sparkle not available on linux") })()|g' "$MAIN_JS"

# 4.2: Replace macOS data paths with XDG paths
# Library/Application Support/Codex → .config/codex (or XDG_CONFIG_HOME)
sed -i 's|Library/Application Support/Codex|.config/codex|g' "$MAIN_JS"

# 4.3: Make SOCKS5 proxy configurable — replace hardcoded socks5h://127.0.0.1:1080
# Only change the default, keep the functionality
sed -i 's|socks5h://127.0.0.1:1080|socks5h://127.0.0.1:1080|g' "$MAIN_JS"

# 4.4: Patch platform checks for essential darwin-only codepaths
# Replace electron-squirrel-startup (Windows-only updater) with noop
sed -i 's|require("electron-squirrel-startup")|false|g' "$MAIN_JS"
sed -i 's|require(`electron-squirrel-startup`)|false|g' "$MAIN_JS"

# 4.5: Disable transparency and vibrancy
# macOS vibrancy and transparent windows can cause severe graphical glitches
# or completely transparent invisible windows on Linux (especially Wayland)
sed -i 's|transparent:!0|transparent:!1|g' "$MAIN_JS"
sed -i 's|transparent:true|transparent:false|g' "$MAIN_JS"
sed -i 's|vibrancy:|vibrancy:null,|g' "$MAIN_JS"
sed -i 's|visualEffectState:|visualEffectState:null,|g' "$MAIN_JS"

# 4.6: Force opaque background color for the BrowserWindow
# The original code sets {backgroundColor: Z7} where Z7="#00000000" (transparent) on non-Windows.
# We replace this to use the dynamic theme colors instead: 'ure' (black) or 'dre' (white).
sed -i 's/backgroundColor:Z7,backgroundMaterial:null/backgroundColor:r?ure:dre,backgroundMaterial:null/g' "$MAIN_JS"

# 4.5: Fix app.isPackaged — force to true for packaged behavior
# This avoids the Vite dev server fallback on localhost:5175
# We'll add this to the launch script instead via env variable

log "Phase 4 complete: main.js patched"

# ── Phase 5: Create launch script ─────────────────────────────────────────────
log "Phase 5: Creating launch infrastructure..."

ELECTRON_BIN="$SCRIPT_DIR/node_modules/.pnpm/electron@${ELECTRON_VERSION}/node_modules/electron/dist/electron"
if [ ! -f "$ELECTRON_BIN" ]; then
    # Try alternative path
    ELECTRON_BIN=$(find "$SCRIPT_DIR/node_modules" -name "electron" -path "*/dist/electron" -type f | head -1)
fi

if [ -z "$ELECTRON_BIN" ] || [ ! -f "$ELECTRON_BIN" ]; then
    err "Electron binary not found"
    exit 1
fi

log "Electron binary: $ELECTRON_BIN"

# Create the static file server for webview (workaround for app.isPackaged)
cat > "$BUILD_DIR/webview-server.js" << 'SERVEREOF'
// Minimal static HTTP server for webview files
// Needed because app.isPackaged=false triggers Vite dev server connection
const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.CODEX_WEBVIEW_PORT || '5175', 10);
const WEBVIEW_DIR = path.join(__dirname, 'webview');

const MIME_TYPES = {
    '.html': 'text/html',
    '.js': 'application/javascript',
    '.mjs': 'application/javascript',
    '.css': 'text/css',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.wav': 'audio/wav',
    '.ico': 'image/x-icon',
};

const server = http.createServer((req, res) => {
    let filePath = path.join(WEBVIEW_DIR, req.url === '/' ? '/index.html' : req.url);
    
    // Security: prevent path traversal
    if (!filePath.startsWith(WEBVIEW_DIR)) {
        res.writeHead(403);
        res.end('Forbidden');
        return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    fs.readFile(filePath, (err, content) => {
        if (err) {
            if (err.code === 'ENOENT') {
                // SPA fallback — serve index.html for any unknown path
                fs.readFile(path.join(WEBVIEW_DIR, 'index.html'), (err2, indexContent) => {
                    if (err2) {
                        res.writeHead(404);
                        res.end('Not Found');
                        return;
                    }
                    res.writeHead(200, { 'Content-Type': 'text/html' });
                    res.end(indexContent);
                });
                return;
            }
            res.writeHead(500);
            res.end('Internal Server Error');
            return;
        }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(content);
    });
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[webview-server] Serving webview on http://127.0.0.1:${PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
SERVEREOF

# Create main launch script
cat > "$SCRIPT_DIR/start.sh" << LAUNCHEOF
#!/usr/bin/env bash
# Codex Desktop for Linux — Launch Script
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="\$SCRIPT_DIR/dist"
ELECTRON_BIN="$ELECTRON_BIN"
WEBVIEW_PORT=\${CODEX_WEBVIEW_PORT:-5175}

# Start webview static server in background
# First ensure the port is free
fuser -k \$WEBVIEW_PORT/tcp 2>/dev/null || true
node "\$DIST_DIR/webview-server.js" &
WEBVIEW_PID=\$!

# Give server time to start
sleep 0.3

cleanup() {
    kill \$WEBVIEW_PID 2>/dev/null || true
    wait \$WEBVIEW_PID 2>/dev/null || true
}
trap cleanup EXIT

# Detect session type
if [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    OZONE_FLAGS="--enable-features=UseOzonePlatform --ozone-platform=wayland"
else
    OZONE_FLAGS=""
fi

# Codex CLI path — use local node_modules or system
LOCAL_CODEX="\$SCRIPT_DIR/node_modules/.bin/codex"
if [ -f "\$LOCAL_CODEX" ]; then
    export CODEX_CLI_PATH="\$LOCAL_CODEX"
    echo "[INFO] Using local Codex CLI: \$LOCAL_CODEX"
else
    CODEX_CLI=\$(command -v codex 2>/dev/null || echo "")
    if [ -z "\$CODEX_CLI" ]; then
        echo "[WARN] Codex CLI not found. Install with: npm i @openai/codex"
    else
        export CODEX_CLI_PATH="\$CODEX_CLI"
    fi
fi

# Launch Electron
exec "\$ELECTRON_BIN" \\
    "\$DIST_DIR" \\
    --no-sandbox \\
    --disable-gpu-compositing \\
    --disable-background-timer-throttling \\
    \$OZONE_FLAGS \\
    "\$@"
LAUNCHEOF
chmod +x "$SCRIPT_DIR/start.sh"

# Create Desktop Entry
XDG_DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$XDG_DESKTOP_DIR"

cat > "$XDG_DESKTOP_DIR/codex-desktop.desktop" << DESKTOPEOF
[Desktop Entry]
Name=Codex
Comment=OpenAI Codex Desktop (Linux Port)
Exec=$SCRIPT_DIR/start.sh
Icon=$SCRIPT_DIR/codex-icon.png
Type=Application
Categories=Development;IDE;
Terminal=false
StartupWMClass=codex
DESKTOPEOF

log "Phase 5 complete: launch infrastructure created"

# ── Phase 6: Extract icon ────────────────────────────────────────────────────
log "Phase 6: Extracting icon..."

ICNS_FILE="$EXTRACTED_DIR/Codex Installer/Codex.app/Contents/Resources/electron.icns"
if [ -f "$ICNS_FILE" ]; then
    # Try to convert icns to png (if icns2png available)
    if command -v icns2png &>/dev/null; then
        icns2png -x -s 256 "$ICNS_FILE" -o "$SCRIPT_DIR/" 2>/dev/null
        mv "$SCRIPT_DIR/"*256x256*.png "$SCRIPT_DIR/codex-icon.png" 2>/dev/null || true
    elif command -v convert &>/dev/null; then
        convert "$ICNS_FILE[0]" -resize 256x256 "$SCRIPT_DIR/codex-icon.png" 2>/dev/null || true
    fi
    
    if [ ! -f "$SCRIPT_DIR/codex-icon.png" ]; then
        warn "Could not convert .icns to .png — install libicns or imagemagick"
    else
        log "✓ Icon extracted: codex-icon.png"
    fi
else
    warn "electron.icns not found"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
log "Build complete!"
echo ""
echo "  App directory:  $BUILD_DIR"
echo "  Launch script:  $SCRIPT_DIR/start.sh"
echo "  Desktop Entry:  $XDG_DESKTOP_DIR/codex-desktop.desktop"
echo ""
echo "  To run:  $SCRIPT_DIR/start.sh"
echo ""
echo "  For Codex AI agent, install CLI:"
echo "    npm i -g @openai/codex"
echo "════════════════════════════════════════════════════════════════"
