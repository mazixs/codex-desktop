# Аудит патчей Codex Desktop для Linux (DMG → Linux)

**Дата аудита:** 2026-05-29  
**Upstream:** macOS Codex Desktop (Electron-based, распространяется как `.dmg`)  
**Цель:** точно определить всё macOS-специфичное, оценить обфускацию/бинаризацию upstream, выявить пробелы в текущих патчах и дать рекомендации по новым строкам.

---

## 1. Архитектура upstream и форматы обфускации

### 1.1 Формат поставки
- **DMG** — образ диска macOS. Внутри `Codex.app/Contents/Resources/app.asar`.
- **app.asar** — архив Electron-приложения. После распаковки (`asar extract`) получаем обычную файловую структуру: `package.json`, `node_modules/`, `.vite/build/`, `webview/`, `skills/`, `native/`.

### 1.2 Обфускация и бинаризация upstream

| Уровень | Что обфусцировано | Как выглядит | Влияние на патчи |
|---------|-------------------|--------------|------------------|
| **JS-бандлы** | Main process, renderer preload, workers | Vite-rollup минификация: `main-BS7yenMI.js`, hashed имена функций (`Ml`, `Nl`, `Pu`, `Fu`), сжатые строки | Патчи используют regex вместо точных имён; имена меняются каждый билд |
| **Asset-хеши** | Иконки, CSS, шрифты в `webview/assets/` | Имена файлов с хешем: `index-BwqrdVu3.js` | Не критично — патчим runtime-логику, не ассеты |
| **Native-модули** | `better-sqlite3`, `node-pty`, `sparkle.node` | `.node` файлы — платформенно-специфичные ELF/Mach-O | Полная пересборка под Linux (см. раздел 5) |
| **Бинарный runtime** | `node_repl` (встроен в DMG) | Может быть Mach-O (macOS) или ELF (Linux primary runtime) | Замена на Linux-версию из OpenAI primary runtime + бинарный патч символов glibc |
| **Marketplace/plugins** | `plugin.json`, `browser-client.mjs` | Частично минифицированы, частично человекочитаемы | Прямая строковая замена + regex |
| **App sunset gate** | JS в `webview/assets/*.js` | Хардкод ID гейта (`2929582856`) | Легко деактивируется через `if(!1&&...)` |

**Вывод:** upstream не использует криптографическую обфускацию или VM-based protection. Это стандартная коммерческая минификация (Vite/Rollup/Terser). Патчи возможны через AST-agnostic regex и literal replacement.

---

## 2. Каталогизация всех патчей (по фазам сборки)

### Фаза A: `prepare_working_copy()` — подготовка рабочей копии

| # | Патч | Цель | macOS-специфично? | Linux-адаптация | Статус |
|---|------|------|-------------------|-----------------|--------|
| A1 | **App sunset gate** | Деактивирует удалённый гейт обновления macOS (`2929582856`) | Да — гейт проверяет macOS-релиз | Убираем проверку полностью (`if(!1&&...)`) | ✅ Работает |
| A2 | **Browser Use: site_status allowlist** | Удаляет `url_request_source` и другие query-params из запроса `site_status`, которые ломают Linux-ноду | Нет — это баг совместимости node_repl | Очистка searchParams | ✅ Работает |
| A3 | **Browser Use: env/processShim** | Маппит `process.env` в `processShim.env`; делает `nodeRepl.env` безопасным | Нет — runtime-совместимость | Fallback на `process.env` | ✅ Работает |
| A4 | **Browser Use: setResponseMeta** | Добавляет optional chaining `?.` | Нет — runtime-совместимость | `setResponseMeta?.(` | ✅ Работает |
| A5 | **Browser Use: nativePipe** | Поддержка `import.meta.__codexNativePipe` | Нет — bridge-совместимость | Добавлен fallback | ✅ Работает |
| A6 | **Chrome: profile roots** | Добавляет Linux-пути к Chrome-профилям (`~/.config/google-chrome`, Brave, Chromium) | Да — upstream знает только `Library/...` и `AppData\...` | Инжект `codexLinuxChromeUserDataDirectories` | ✅ Работает |
| A7 | **Chrome: profile metadata matching** | Позволяет матчить профили по `userDataDir` в Linux | Да | Реструктуризация `find`/`list` функций | ✅ Работает |
| A8 | **Chrome: installed browsers** | Добавляет Brave и Chromium в список известных браузеров | Нет — функциональность | `KNOWN_BROWSERS` + Linux commands | ✅ Работает |
| A9 | **Chrome: open-chrome-window** | Автоопределение бинаря Chrome на Linux | Да | Список кандидатов + `commandPath` | ✅ Работает |
| A10 | **Chrome: check-extension-installed** | Linux-пути к профилям для проверки расширения | Да | `linuxDirs` в `getChromeUserDataDir` | ✅ Работает |
| A11 | **Chrome: installManifest** | `NativeMessagingHosts` пути для Linux | Да | `.config/...` пути для Brave, Chromium | ✅ Работает |
| A12 | **Plugin version suffix** | Добавляет `-linux.1` к версиям плагинов | Нет — идентификация | Версионирование | ✅ Работает |
| A13 | **node_repl замена** | Замена Mach-O `node_repl` на Linux ELF | Да — бинарный компонент | Скачивание из OpenAI primary runtime + glibc patch | ✅ Работает |
| A14 | **node symlink** | `dist/node` → системный `node` | Нет — fallback для Browser Use | Симлинк | ✅ Работает |
| A15 | **Marketplace filter** | Убирает `computer-use` (macOS-only bundle) из marketplace | Да — computer-use это macOS app | Фильтрация по allowlist | ✅ Работает |

### Фаза B: `rebuild_native_modules()` — нативные модули

| # | Патч | Цель | macOS-специфично? | Linux-адаптация | Статус |
|---|------|------|-------------------|-----------------|--------|
| B1 | **Удаление `sparkle.node`** | macOS автоапдейтер (Sparkle framework) | Да — полностью macOS | `rm -f` | ✅ Работает |
| B2 | **better-sqlite3 rebuild** | Пересборка под Linux + V8 sandbox patch | Да — Mach-O → ELF | `electron-rebuild` + патч `v8::External` | ✅ Работает |
| B3 | **node-pty rebuild** | Пересборка под Linux | Да — Mach-O → ELF | `electron-rebuild` | ✅ Работает |

### Фаза C: `patch_main_js()` — главный Electron бандл

| # | Патч | Цель | macOS-специфично? | Linux-адаптация | Статус |
|---|------|------|-------------------|-----------------|--------|
| C1 | **Browser Use trusted client hash** | Синхронизация SHA-256 хеша `browser-client.mjs` | Нет — security trust chain | Замена единственного хеша в бандле | ✅ Работает |
| C2 | **Chrome plugin auto-install gate** | Заставляет Chrome-плагин вести себя как Browser Use (auto-install) | Нет — функциональность | `installWhenMissing:!0` | ✅ Работает |
| C3 | **Opaque background (transparent→dark/light)** | macOS vibrancy использует `#00000000`; на Linux это ломает фон | Да — `backgroundMaterial`, `vibrancy` | Linux-ветка с `backgroundColor` и `backgroundMaterial:null` | ✅ Работает |
| C4 | **UY window type (`panel` → `utility`)** | На macOS `type:'panel'` для utility windows; на Linux нужен `type:'utility'` | Да | `...platform===`linux`?{type:`utility`}:{}` | ✅ Работает |
| C5 | **hotkeyWindowHome/Thread opacity** | `transparent:!1` на macOS → `transparent:platform!==`linux`` | Да | Условное прозрачность | ✅ Работает |
| C6 | **Vibrancy / visualEffectState / backgroundMaterial** | `vibrancy:"menu"` → `null`, `visualEffectState:"active"` → `null`, `backgroundMaterial:"mica"` → `null` | Да — macOS/Windows эффекты | Замена на `null` | ✅ Работает |
| C7 | **autoHideMenuBar** | Скрывать меню только на Win32 → добавить Linux | Нет — UX | `win32||linux` | ✅ Работает |
| C8 | **removeMenu() на Linux** | Удаление нативного меню окна на Linux | Нет — UX | `win32||linux` → `removeMenu()` | ✅ Работает |
| C9 | **setApplicationMenu(null)** | Полное отключение глобального меню приложения на Linux | Нет — UX | `process.platform===`linux`?Menu.setApplicationMenu(null)` | ✅ Работает |
| C10 | **Linux file manager** | Добавляет `xdg-open` для "Open folder" | Да — только darwin/win32 | `linux:{label:`File Manager`,detect:()=>`xdg-open`,...}` | ✅ Работает |
| C11 | **Linux terminal** | Добавляет поддержку терминалов Linux (gnome-terminal, kitty, alacritty и т.д.) | Да — только darwin/win32 | Инжект 5 helper-функций + `linux:` платформа | ✅ Работает |
| C12 | **Linux editor targets (structural)** | Добавляет `linuxDetect`/`linuxPathCommands`/`linuxArgs` в factory-функции редакторов | Да — только darwin/win32 | Regex-based structural patch | ✅ Работает |
| C13 | **Editor instances** (Cursor, VS Code, Zed, Sublime, Windsurf, JetBrains, etc.) | Конкретные детекторы для каждого редактора | Да — пути `/Applications/...` | `linuxDetect`/`linuxPathCommands` для каждого | ✅ Работает |
| C14 | **Skills path function** | Поиск `skills/` относительно `getAppPath()` | Нет — относится к упаковке | Добавлены fallback-пути (`../skills`, `../assets/skills`) | ✅ Работает |
| C15 | **Skills loader: bundled overrides** | Поддержка `SKILLS_OVERRIDE_DIR` и merge-логики | Нет — Linux packaging | Инжект `mergeRecommendedSkillLists`, `logBundledSkillOverrides`, `normalizeSkillIconUrl` | ✅ Работает |
| C16 | **Skills loader: priority flip** | Bundled skills должны иметь приоритет над remote/git | Нет — Linux offline-first | Инверсия логики `if(t)` в resolver'ах | ✅ Работает |
| C17 | **comment-preload.js screenshots** | Стабилизация скриншотов аннотаций (отключает live element lookup) | Нет — баг рендеринга | Замена на прямой `Sd(F.anchor)` | ✅ Работает |

### Фаза D: `apply_linux_desktop_identity()`

| # | Патч | Цель | macOS-специфично? | Linux-адаптация | Статус |
|---|------|------|-------------------|-----------------|--------|
| D1 | **package.json metadata** | `desktopName`, `productName` | Нет — идентификация | `codex-desktop.desktop`, `Codex Desktop` | ✅ Работает |

### Фаза E: `start.sh` — runtime launcher

| # | Патч | Цель | macOS-специфично? | Linux-адаптация | Статус |
|---|------|------|-------------------|-----------------|--------|
| E1 | **Ozone/Wayland flags** | `--ozone-platform=wayland` при `XDG_SESSION_TYPE=wayland` | Нет — Linux display server | Автоопределение | ✅ Работает |
| E2 | **Browser Use env vars** | `CODEX_ELECTRON_RESOURCES_PATH`, `CODEX_BROWSER_USE_NODE_PATH`, `CODEX_NODE_REPL_PATH` | Нет — runtime wiring | Экспорт переменных | ✅ Работает |
| E3 | **node_repl MCP auto-register** | `codex mcp add node_repl` | Нет — CLI интеграция | Авто-добавление MCP сервера | ✅ Работает |
| E4 | **URL scheme handlers** | `codex://`, `codex-browser-sidebar://` | Да — xdg-mime | `xdg-mime default` | ✅ Работает |
| E5 | **Electron binary robust extraction** | Скачивание Electron при отсутствии | Нет — portable artifact | `@electron/get` + unzip | ✅ Работает |

---

## 3. Что осталось macOS-специфичным и НЕ пропатчено (GAP-анализ)

### 3.1 🔴 High Risk — потенциально ломает функциональность на Linux

#### GAP-1: `native-menu-locales/` — macOS Native Menus
- **Где:** `codex_extracted/app_unpacked/native-menu-locales/` (~50 JSON-файлов локализаций)
- **Что это:** Локализации для нативного macOS меню (NSMenu). Upstream использует `native-menu-locales/` для генерации меню через Electron `Menu.buildFromTemplate()` или нативные API.
- **Проблема:** На Linux мы отключаем меню через `setApplicationMenu(null)` (C9). Эти локализации становятся мёртвым грузом, но их присутствие не ломает функциональность. Однако если upstream начнёт использовать эти локали для чего-то другого (например, контекстное меню), может потребоваться адаптация.
- **Рекомендация:** Мониторить. Пока не требует патча.

#### GAP-2: `process.platform===`darwin`` в `worker.js` (2 вхождения) и `app-session-gBTKZRaX.js` (2 вхождения)
- **Где:** `worker.js`, `app-session-*.js`
- **Что это:** Worker-потоки и сессия приложения.
- **Проблема:** После грепа видно, что эти вхождения находятся внутри больших минифицированных библиотек (ajv, glob, и т.п.) и, скорее всего, относятся к platform-detection внутри зависимостей, а не к бизнес-логике Codex. Однако если в `app-session` есть проверка `darwin` для работы с файловой системой (например, `~/Library/...`), это может быть проблемой.
- **Рекомендация:** Провести disassembly вхождений. Вероятно, не критично, но нужно убедиться.

#### GAP-3: `workspace-root-drop-handler` — `process.platform===`darwin`` (3), `win32` (30)
- **Где:** `workspace-root-drop-handler-DJwLZgXt.js`
- **Что это:** Обработчик drag-and-drop файлов в workspace.
- **Проблема:** 3 вхождения `darwin` и 30 `win32`. Linux (`process.platform===`linux``) — только 1. Это может означать, что drag-and-drop на Linux не поддерживается или работает через win32-фоллбек.
- **Рекомендация:** Исследовать. Если DnD для файлов/папок не работает в Linux-сборке, вероятно, причина здесь. Нужно добавить Linux-ветку или убедиться, что win32-fallback корректен.

#### GAP-4: Bootstrap и Preload — `process.platform===`darwin`` / `win32`
- **Где:** `bootstrap.js`, `preload.js`, `sandbox-preload.js`
- **Что это:** Bootstrap и preload скрипты Electron.
- **Проблема:** В `bootstrap.js` есть 1 `win32` и 1 `darwin`. Это может быть связано с protocol handlers, sandbox или native messaging.
- **Рекомендация:** Проверить конкретные строки. Если это gate для нативных фич, возможно, Linux-ветка отсутствует.

#### GAP-5: `node_repl` — glibc compatibility patch (текущий подход костыльный)
- **Где:** `patch_node_repl_glibc_pidfd_symbols()` (Python ELF-patcher)
- **Что это:** OpenAI primary runtime `node_repl` скомпилирован против glibc 2.39 (`pidfd_spawn`). На системах с glibc < 2.39 бинарь падает.
- **Текущий подход:** Бинарный патч ELF dynamic symbol table: меняет `GLIBC_2.39` → `GLIBC_2.34` для `pidfd_spawn` и `pidfd_open`.
- **Проблема:** Это хак на уровне ELF. Если OpenAI обновит runtime и добавит другие символы 2.39+, патч сломается. Также не работает на musl (Alpine).
- **Рекомендация:**
  - Добавить проверку `ldd --version` перед патчем.
  - Рассмотреть bundling statically-linked `node_repl` или сборку из исходников.
  - Добавить fallback: если `patchelf` не сработал, предупреждать пользователя.

### 3.2 🟡 Medium Risk — упущенные возможности или UX-проблемы

#### GAP-6: Отсутствие Linux-специфичных notification APIs
- **Где:** Возможно, в main bundle
- **Что это:** macOS использует `electron-notification` или `NSUserNotification`. На Linux нужен `libnotify` через Electron `Notification` API (обычно работает из коробки через Chromium).
- **Проблема:** Если upstream использует кастомные нотификации (badge, sound, actions), они могут не работать.
- **Рекомендация:** Проверить использование `new Notification()` и `app.setBadgeCount()`. На Linux badge обычно требует Unity launcher API или DBus.

#### GAP-7: Tray / Dock иконка
- **Где:** Main bundle
- **Что это:** macOS использует `app.dock.setIcon()` и `Tray` с template image.
- **Проблема:** На Linux `app.dock` отсутствует (только macOS API). Если upstream не проверяет `process.platform`, может вылететь exception.
- **Рекомендация:** Поискать `app.dock` в main bundle. Если есть без platform guard — добавить патч.

#### GAP-8: Keychain / credential storage
- **Где:** Возможно, в main bundle или плагинах
- **Что это:** macOS использует Keychain (`security` CLI или `keytar`).
- **Проблема:** На Linux нет Keychain. Если Codex хранит токены в macOS Keychain, на Linux это не работает.
- **Рекомендация:** Поискать `keychain`, `keytar`, `security find-generic-password` в бандлах. Вероятно, upstream использует собственное хранилище (Chrome storage или файл), но стоит проверить.

#### GAP-9: Update checker / auto-updater
- **Где:** Main bundle
- **Что это:** Sparkle удалён (B1), но JS-логика проверки обновлений может оставаться.
- **Проблема:** Если upstream делает HTTP-запрос на проверку macOS-релиза, это бесполезный трафик и возможные ошибки.
- **Рекомендация:** Поискать `checkForUpdates`, `update-available`, `version-check` в main bundle. Заменить на no-op для Linux.

#### GAP-10: Sandbox / Entitlements логика
- **Где:** Main bundle
- **Что это:** macOS использует `app.setSecureKeyboardEntryEnabled()`, `systemPreferences.askForMediaAccess()`.
- **Проблема:** Эти API вызывают exception или no-op на Linux, но если код не обёрнут в `darwin` guard, может быть warning.
- **Рекомендация:** Поискать `secureKeyboardEntry`, `askForMediaAccess`, `entitlements` в main bundle.

#### GAP-11: `comment-preload.js` — 39MB бандл
- **Где:** `comment-preload.js` (~39MB)
- **Что это:** Огромный бандл, вероятно, содержит весь React-runtime + editor.
- **Проблема:** Патчи C17 есть, но бандл настолько велик, что любые runtime-ошибки в нём трудно дебажить.
- **Рекомендация:** Проверить, не содержит ли он platform-specific код (например, `process.platform` в renderer context, который всегда равен `browser`, но может использовать `navigator.userAgent`).

### 3.3 🟢 Low Risk — косметические или нефункциональные различия

#### GAP-12: DMG-брендинг
- **Где:** `Codex.dmg` содержит `.background/`, `Applications` symlink
- **Что это:** macOS-специфичный брендинг установщика.
- **Проблема:** Нет — мы не используем DMG на Linux.
- **Рекомендация:** N/A.

#### GAP-13: `electron.icns`
- **Где:** `Codex.app/Contents/Resources/electron.icns`
- **Что это:** macOS icon format.
- **Проблема:** Конвертируется в PNG для Linux.
- **Рекомендация:** N/A.

---

## 4. Бинарные компоненты: детальный разбор

### 4.1 `node_repl`
- **Исходный формат:** Mach-O (если из DMG) или ELF (если из primary runtime).
- **Что делает:** Node.js-based REPL / MCP server для Browser Use. Имеет привилегированный доступ к native pipe.
- **Патчи:**
  1. Замена бинарника на Linux-версию.
  2. ELF symbol version patch (`pidfd_*` GLIBC_2.39 → 2.34).
- **Риски:** Бинарный патч ломается при обновлении upstream runtime. Необходим мониторинг.

### 4.2 `better-sqlite3.node`
- **Исходный формат:** Mach-O.
- **Что делает:** SQLite доступ из Node/Electron.
- **Патчи:** Полная пересборка + V8 sandbox patch (Electron 42+ external pointers).
- **Риски:** Минимальны. upstream-зависимость фиксирована (`12.10.0`).

### 4.3 `node-pty.node`
- **Исходный формат:** Mach-O.
- **Что делает:** PTY (pseudo-terminal) для встроенного терминала.
- **Патчи:** Пересборка.
- **Риски:** Минимальны.

### 4.4 `sparkle.node`
- **Исходный формат:** Mach-O (Sparkle.framework wrapper).
- **Что делает:** Автообновление macOS.
- **Патчи:** Удаление.
- **Риски:** Нет.

---

## 5. Рекомендации по новым строкам в патчах

### 5.1 🔴 Критические — добавить в ближайшем релизе

#### REC-1: Drag-and-Drop handler (`workspace-root-drop-handler`)
```bash
# Добавить в patch_main_js после существующих патчей:
python3 - "$workspace_bundle" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, "r").read()
# Найти DnD логику и добавить linux-ветку, если win32/darwin only
# Примерный паттерн (требует реверса конкретного upstream):
# content, count = re.subn(
#     r'(process\.platform===`win32`\?...:process\.platform===`darwin`\?...:)',
#     r'\1process.platform===`linux`?...:',
#     content
# )
open(path, "w").write(content)
PY
```

#### REC-2: `app.dock` guard
```bash
# Добавить в patch_main_js:
python3 - "$main_bundle" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, "r").read()
# Заменить прямые вызовы app.dock на guarded
content = re.sub(
    r'([A-Za-z_$][\w$]*)\.dock\.setIcon\(',
    r'(process.platform!==`linux`&&\1.dock.setIcon(',
    content
)
content = re.sub(
    r'([A-Za-z_$][\w$]*)\.dock\.setBadge\(',
    r'(process.platform!==`linux`&&\1.dock.setBadge(',
    content
)
open(path, "w").write(content)
PY
```

#### REC-3: Keychain / credential storage guard
```bash
# Добавить в patch_main_js:
python3 - "$main_bundle" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, "r").read()
# Если найден keytar или keychain access — заменить на Linux fallback (fs-based)
if 'keytar' in content or 'keychain' in content:
    print("WARN: Potential keychain dependency detected — review required", file=sys.stderr)
open(path, "w").write(content)
PY
```

#### REC-4: Update checker no-op
```bash
# Добавить в patch_main_js:
python3 - "$main_bundle" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, "r").read()
# Паттерн: autoUpdater.checkForUpdates() или подобное
# Заменить на no-op для linux
content = re.sub(
    r'(process\.platform===`linux`[^{]*\{[^}]*)(checkForUpdates|checkForUpdatesAndNotify)\(',
    r'\1/*linux-noop*/void 0;',
    content
)
open(path, "w").write(content)
PY
```

#### REC-5: `node_repl` glibc fallback + musl warning
```bash
# В patch_node_repl_glibc_pidfd_symbols() добавить:
if ldd_version < "2.39"; then
    patch_elf_symbols
else
    log "System glibc supports pidfd_spawn natively, skipping ELF patch"
fi

# Добавить detection musl:
if ldd_output contains "musl"; then
    warn "musl libc detected: node_repl may not function without static linking"
fi
```

### 5.2 🟡 Рекомендуемые — улучшение UX

#### REC-6: Linux notification badge (Unity/DBus)
```bash
# Если найдено setBadgeCount в main bundle:
python3 - "$main_bundle" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, "r").read()
# На Linux setBadgeCount работает только в Unity. Добавить guard.
content = re.sub(
    r'([A-Za-z_$][\w$]*)\.setBadgeCount\(',
    r'(process.platform===`linux`?require(`electron`).app.setBadgeCount===void 0?null:\1.setBadgeCount(:\1.setBadgeCount(',
    content
)
open(path, "w").write(content)
PY
```

#### REC-7: Поддержка `Ctrl+Q` как quit accelerator на Linux
```bash
# В main bundle, где определяются accelerators:
replace_first_available "$main_bundle" 0 \
    'accelerator:"Cmd+Q"' 'accelerator:process.platform===`darwin`?"Cmd+Q":"Ctrl+Q"' \
    'accelerator:"Cmd+W"' 'accelerator:process.platform===`darwin`?"Cmd+W":"Ctrl+W"'
```

#### REC-8: Linux window manager hints (`skipTaskbar` для utility windows)
```bash
# В дополнение к type:'utility' (C4), добавить skipTaskbar где применимо:
python3 - "$main_bundle" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, "r").read()
# Найти создание utility windows и добавить skipTaskbar:true для linux
content = re.sub(
    r'(type:`utility`,)',
    r'skipTaskbar:true,\1',
    content
)
open(path, "w").write(content)
PY
```

### 5.3 🟢 Опциональные — технический долг

#### REC-9: Source maps для patched bundles
- Текущие патчи модифицируют `.js` без обновления `.map`. Это ломает source mapping при отладке.
- **Решение:** Либо удалять `.map` (чтобы DevTools не пытался мапить), либо использовать `@jridgewell/trace-mapping` для корректировки mappings.

#### REC-10: Автоматизированный regression test для патчей
```bash
# Новый скрипт tests/patch-regression.sh:
#!/usr/bin/env bash
# Проверяет, что все критические паттерны присутствуют в dist/
set -euo pipefail

main_bundle="${1:?}"

grep -q 'process.platform===`linux`.*type:`utility`' "$main_bundle" || { echo "FAIL: UY window type patch"; exit 1; }
grep -q 'linux:{label:`Terminal`' "$main_bundle" || { echo "FAIL: Terminal patch"; exit 1; }
grep -q 'linux:{label:`File Manager`' "$main_bundle" || { echo "FAIL: File Manager patch"; exit 1; }
grep -q 'setApplicationMenu(null)' "$main_bundle" || { echo "FAIL: App menu patch"; exit 1; }
grep -q 'backgroundMaterial:null' "$main_bundle" || { echo "FAIL: backgroundMaterial patch"; exit 1; }
echo "PASS: All critical patches present"
```

#### REC-11: Удаление `native-menu-locales/` из артефакта
- Эти файлы занимают место и бесполезны на Linux. Можно исключить из `dist/` при копировании.

---

## 6. Сводная таблица: что определяет macOS, что делает, нужна ли адаптация

| Компонент | Определяет macOS? | Что делает | Адаптировано? | Как адаптировано | Нужны новые патчи? |
|-----------|-------------------|------------|---------------|------------------|-------------------|
| DMG / Codex.app | Да | Упаковка / подпись | ✅ Да | asar extract | Нет |
| app.asar | Нет | Архив приложения | ✅ Да | asar extract | Нет |
| `native-menu-locales/` | Да | Локализации NSMenu | ⚠️ Частично | Меню отключено | Мониторить |
| `sparkle.node` | Да | Автоапдейт | ✅ Да | Удаление | Нет |
| `node_repl` (Mach-O) | Да | MCP / REPL runtime | ✅ Да | Замена на Linux ELF + glibc patch | Да (musl, static link) |
| `better-sqlite3.node` | Да | База данных | ✅ Да | Пересборка + V8 patch | Нет |
| `node-pty.node` | Да | Псевдотерминал | ✅ Да | Пересборка | Нет |
| `main-*.js` window effects | Да | Vibrancy, backgroundMaterial | ✅ Да | null + opaque bg | Нет |
| `main-*.js` UY window type | Да | `type:'panel'` | ✅ Да | `type:'utility'` для linux | Нет |
| `main-*.js` hotkey windows | Да | Прозрачность | ✅ Да | `transparent:platform!==linux` | Нет |
| `main-*.js` app menu | Да | setApplicationMenu | ✅ Да | setApplicationMenu(null) | Нет |
| `main-*.js` open targets | Да | Darwin/Win32 only | ✅ Да | Инжект linux-платформ | Нет |
| `main-*.js` skills loader | Нет | Git/cached skills | ✅ Да | Bundled override + merge | Нет |
| `comment-preload.js` | Нет | Screenshot stabilization | ✅ Да | Прямой anchor access | Нет |
| `worker.js` platform checks | Возможно | Внутри deps (glob/ajv) | ❓ Неизвестно | — | Да (проверить) |
| `app-session-*.js` | Возможно | Session logic | ❓ Неизвестно | — | Да (проверить) |
| `workspace-root-drop-handler` | Возможно | DnD files | ❓ Неизвестно | — | Да (REC-1) |
| `bootstrap.js` / `preload.js` | Возможно | Protocol/sandbox | ❓ Неизвестно | — | Да (проверить) |
| Update checker (JS) | Да | HTTP check macOS release | ❌ Нет | — | Да (REC-4) |
| Keychain / keytar | Да | Хранение credentials | ❌ Не проверено | — | Да (REC-3) |
| `app.dock` | Да | Dock icon / badge | ❌ Не проверено | — | Да (REC-2) |
| Notifications badge | Частично | setBadgeCount | ❌ Не проверено | — | Да (REC-6) |

---

## 7. Заключение

### Что хорошо
1. **Покрытие основных патчей очень высокое.** Window management, open targets, native modules, Browser Use runtime — всё адаптировано.
2. **Стратегия regex-based patching** корректна для минифицированного upstream. `replace_first_available` с multiple fallback strings эффективно решает проблему drifting minified names.
3. **Skills override system** (`packaging/skills-overrides/`) — архитектурно правильное решение для Linux-специфичных скиллов.

### Главные риски
1. **Бинарный ELF-patch `node_repl`** — хрупкий костыль. Требует fallback на static linking или контейнеризацию.
2. **Неисследованные platform checks** в `worker.js`, `app-session`, `bootstrap.js`, `workspace-root-drop-handler`. Это потенциальные landmines.
3. **Отсутствие regression tests** для патчей. Если upstream изменит архитектуру, патчи начнут молча фейлиться (warning в stderr, но билд продолжится).

### Приоритет действий
| Приоритет | Действие | Владелец |
|-----------|----------|----------|
| P0 | Добавить `tests/patch-regression.sh` (REC-10) | Build engineer |
| P0 | Исследовать `workspace-root-drop-handler` DnD (GAP-3 / REC-1) | Reverse engineer |
| P1 | Проверить `app.dock`, `setBadgeCount`, keychain (GAP-7,8 / REC-2,3,6) | Electron developer |
| P1 | Добавить musl-guard для `node_repl` (GAP-5 / REC-5) | Build engineer |
| P2 | Удалить `native-menu-locales` из артефакта (REC-11) | Build engineer |
| P2 | Source maps cleanup (REC-9) | DevEx |

---

*Аудит проведён с позиции Senior+ Electron Developer. Анализ основан на реверсе `build.sh`, `start.sh`, `webview-server.js` и извлечённых артефактов upstream DMG.*
