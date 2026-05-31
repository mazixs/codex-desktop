# ADR 0002: Resilient Dynamic Python-Based Patching Strategy

## Context
As upstream Codex Desktop releases evolve, the bundled JavaScript output undergoes minification and obfuscation. Variable names, namespace aliases (such as `t`, `n`, `i`, `e`), and function wrappers drift and change with every compilation.
Initially, the Linux build script ([build.sh](file:///home/mazix/Documents/GitHub/codex-desktop/codex-linux-build/build.sh)) used literal string replacements (`replace_first_available`) for modifying complex subsystems like the recommended-skills loader (e.g., `HL`, `VL`, `BL`, `lR`) and comments manager (`comment-preload.js`).
This static strategy frequently broke upon minor upstream version updates because:
1. Minified function signatures shifted entirely.
2. Identifiers representing path engines or server clients changed dynamically.
3. Complex nested try-catch blocks in loaders were truncated or corrupted when relying on naive string slices.

## Decision
We will migrate all complex AST-like and token-sensitive replacements in `main.js`, the recommended-skills bundle, and `comment-preload.js` to dynamic inline Python patching routines inside [build.sh](file:///home/mazix/Documents/GitHub/codex-desktop/codex-linux-build/build.sh):
1. **Structural Regular Expressions:** Utilize abstract regular expressions that target function topologies and parameter patterns (e.g., targeting `async function \w+({repoRoot:\w+,recommendedRoots:\w+})` rather than specific minified names).
2. **Dynamic Name Binding:** Capture the minified variable names dynamically during regex matching and re-use them inside the generated replacement blocks to preserve structural integrity.
3. **Balanced Curly Brace Parsing (`find_matching_brace`):** Implement a brace-tracking algorithm in Python to dynamically detect the boundaries of complex nested JavaScript constructs (like the try-catch block inside recommended-skills loader `BL`), avoiding naive split/replace bugs.
4. **Offline Base64 Asset Normalization:** Intercept recommended-skill asset loaders (`normalizeSkillIconUrl`) to load and inline icons as Base64 data URLs, resolving Web Security mixed-content policies on Linux.

## Alternatives
* **Static String Replacements (`replace_first_available`):** Abandoned because it requires manual maintenance on every single upstream release.
* **Full AST Parsing (e.g., using Babel or Esprima via Node):** While robust, this introduces additional Node-based build-time dependencies, increases complexity, and slows down the build process compared to inline Python scripts.

## Consequences
* **Pros:**
  * Near 100% resilience against upstream minification and variable name drift.
  * Ensures future updates to `Codex.dmg` can be packaged and patched automatically by CI.
  * Cleaner build output and detailed logging of successful patch applications.
* **Cons:**
  * Inline Python regular expressions are complex and require deep understanding of minified bundle topologies.
