# Changelog

## Unreleased

Initial extraction from [SwiftStan](https://github.com/SwiftProjectOrganization/SwiftStan).

### Changes from SwiftStan
- Library-only product (`SwiftStan`); no `swiftstan` executable, no `swift-argument-parser` dependency.
- `dsl2stan` removed (it recompiled the package's own source tree via `swiftc` — not viable in a distributed library; the in-process `stancode` covers the alist→Stan path).
- `caseRootOverride` demoted from `public` to `internal` (test-only redirect hook; reachable via `@testable import SwiftStan`).
- Internal plumbing in `Methods/`, `Support/`, and `Ulam/` demoted to `internal`.
- Test target restructured to idiomatic SPM layout with `Unit/` and `Integration/` subdirs; integration tests skip automatically when `$CMDSTAN` is unset.
