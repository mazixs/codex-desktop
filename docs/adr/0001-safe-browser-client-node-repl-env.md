# ADR 0001: Safe Access to `nodeRepl.env` in Browser Client

## Context
During runtime initialization of the Codex Desktop app for Linux, the guest runtime executes scripts inside a sandboxed `node_repl` context. The host process injects a global `nodeRepl` object into this context.

However, in the Linux environment, `globalThis.nodeRepl.env` is undefined, and the `nodeRepl` object itself is frozen/non-extensible (making it impossible to assign `nodeRepl.env = {}` dynamically).

When the `@openai-bundled-dev/browser` plugin's `browser-client.mjs` is imported, it boots up via `setupBrowserRuntime({ globals: globalThis })`. During this setup:
1. The global `process` object is replaced by a secure `processShim` with an empty `env: {}` dictionary.
2. The internal config lookup helper `lu(e)` executes `globalThis.nodeRepl?.env[e]`. Because `nodeRepl.env` is undefined, this attempts to index `undefined`, throwing `TypeError: Cannot read properties of undefined (reading 'BROWSER_USE_DISABLE_AMBIENT_NETWORK')` and halting initialization.
3. The response metadata injector `PT()` calls `nodeRepl?.setResponseMeta()`. If `setResponseMeta` is missing on the guest `nodeRepl` object, this throws a `TypeError`.

## Decision
We will patch the generated/extracted plugin file `browser-client.mjs` during the build phase inside [build.sh](file:///home/mazix/Documents/GitHub/codex-desktop/codex-linux-build/build.sh):
1. **Preserve Environment Variables:** Map the real process environment variables (`process.env`) into the `processShim.env` object before `process` is overridden.
2. **Safe Property Access & Fallback:** Patch the `lu(e)` function to safely access `nodeRepl?.env` using optional chaining (`?.env?.[e]`) and fall back to the preserved `globalThis.process?.env` context.
3. **Safe Method Invocation:** Patch the `PT(e)` helper to safely call `setResponseMeta` using optional chaining (`e.nodeRepl?.setResponseMeta?.(...)`).

## Alternatives
* **Modifying the node_repl Binary:** Not feasible as it is a closed-source precompiled binary from upstream.
* **Extending nodeRepl dynamically:** Attempted, but fails with `TypeError: Cannot add property env, object is not extensible`.

## Consequences
* **Pros:** Safely bypasses the crash during plugin bootstrap. Restores correct reading of configuration variables (e.g. `BROWSER_USE_DISABLE_AMBIENT_NETWORK`) from the real environment.
* **Cons:** Introduces regex-based patches in the build script that must be verified when the upstream version changes.
