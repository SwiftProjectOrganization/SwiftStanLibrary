# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

SwiftStanLibrary is a **library-only** Swift package (no CLI, no executable) that exposes 13 public commands and a Swift result-builder DSL for interacting with [cmdstan](https://mc-stan.org/docs/2_37/cmdstan-guide/). macOS 14+; Swift 6; no external dependencies.

Extracted from [SwiftStan](https://github.com/SwiftProjectOrganization/SwiftStan). The canonical SwiftStan package (with CLI) is at `../SwiftStan`; this package is the curation of its library layer for downstream consumers.

The design rationale lives in `../SwiftStan/Docs/SwiftStanServer-Plan.md`.

## Build & test

```bash
swift build

# Unit tests only (portable, no cmdstan needed)
swift test

# Unit + integration tests
CMDSTAN=/path/to/cmdstan swift test
```

Integration test suites (under `Tests/SwiftStanLibraryTests/Integration/`) are gated with `.enabled(if: ProcessInfo.processInfo.environment["CMDSTAN"] != nil, ...)` — they skip automatically when `$CMDSTAN` is unset.

## Architecture

The module name is `SwiftStan` (package name is `SwiftStanLibrary`), so consumers write `import SwiftStan` and existing imports in servers/apps that used the original `SwiftStan` library work unchanged.

### Source layout (`Sources/SwiftStan/`)

- `Commands/` — the 13 public command functions (top-level free functions). This is the primary public API.
- `Methods/` — **internal** low-level cmdstan argument builders / shell-out wrappers (called by Commands, not entry points).
- `Support/` — mixed: `CasePaths`, `RunInfoIO`, `StanSchema` are public (useful to consumers navigating the case layout or reading run output); the rest is **internal** post-processing plumbing.
- `Helpers/` — **internal** bootstrap helpers (install example files).
- `Ulam/` — the DSL and codegen engine:
  - `AST/`, `Builder/`, `Data/` — all **public** (the result-builder DSL contract).
  - `Generator/` — `StanCodeGenerator` is **internal**; the public entry is `stancode(_ model: UlamModel) throws -> String`.
  - `Alist/`, `Stan2Alist/` — **internal** (parser/emitter pipeline types).

### Key missing command vs. original SwiftStan

`dsl2stan` is **not** in this library — it recompiles the package's own `Ulam/` source tree via `swiftc`, which is not viable in a distributed binary. Use `stancode` (in-process, fast) instead; if you need a smoke driver for prototyping, use `alist2dsl` first, then hand it to the original `SwiftStan` CLI.

### `(String, String)` return convention

The cmdstan-backed commands return `(status, errorOrEmpty)`:
- `.0` — human-readable status line.
- `.1` — error message (`""` on success). Callers branch on `.1 == ""`.

This is the same convention as the original `SwiftStan` CLI; don't replace it with `throws` piecemeal.

### Path resolution

`Support/CasePaths.swift` owns the `$STAN_CASES` → `~/Documents/StanCases/` default resolution. The internal `caseRootOverride` global redirects tests to a `_Test` sibling dir (accessed via `@testable import SwiftStan` in the test target only — it is **not** part of the public API).

## Key constraints

- macOS 14+; Swift 6. No external dependencies.
- Do **not** add `swift-argument-parser` — the library must stay dependency-free. The CLI lives in `../SwiftStan`.
- Do **not** re-expose `caseRootOverride` as `public`. It is internal on purpose.
- Keep access levels: `Commands/` entry points and DSL types public; `Methods/`, `Helpers/`, support plumbing internal.
- When syncing from upstream `../SwiftStan/Sources/SwiftStan/`:
  1. `rsync -a --delete ../SwiftStan/Sources/SwiftStan/ Sources/SwiftStan/`
  2. Re-delete `Sources/SwiftStan/Commands/Dsl2Stan.swift`
  3. Re-apply the access-level demotions (see CHANGELOG.md for the full list)
  4. Re-apply the `caseRootOverride` demotion in `Support/CasePaths.swift`
  5. Re-apply the `dsl2stan` fallback removal in `Ulam/Ulam.swift`
  6. `swift build` to verify

## Tests

`Tests/SwiftStanLibraryTests/`:
- `Unit/` — 183 portable pure-Swift tests. No cmdstan. Green on any machine.
- `Integration/` — cmdstan shell-out tests. Skipped when `$CMDSTAN` is unset.
- `Resources/` — bundled test fixtures (CSV, alist.R, ulam.swift); loaded via `Bundle.module`.
- `TestCaseRootBootstrap.swift` — redirects `casePaths(for:)` to a `_Test` sibling dir.
- `TestFixtureStaging.swift` — copies bundled fixtures into the `_Test` case dirs.

Every `@Suite` struct's `init()` must start with `_ = TestCaseRootBootstrap.install`.
