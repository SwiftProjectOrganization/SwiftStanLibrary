//
//  TestCaseRootBootstrap.swift
//  SwiftStanTests
//
//  Module-load hook that redirects every `casePaths(for:)` call made
//  by the test bundle into a sibling `~/Documents/<STAN_CASES>_Test/`
//  directory, so a `swift test` run never touches the user's real
//  production `<STAN_CASES>/<name>/` case dirs.
//
//  Mechanism:
//   • Every `@Suite` struct's `init()` references
//     `TestCaseRootBootstrap.install`.
//   • Swift's static-let semantics guarantee the `install` closure
//     runs exactly once, before any test body executes.
//   • The closure sets `SwiftStan.caseRootOverride` to
//     `<Documents>/<STAN_CASES>_Test/`. From that point on every
//     `caseRoot()` call returns the redirect.
//
//  The redirect base name follows the user's `$STAN_CASES` env var if
//  set (so `STAN_CASES=MyCases` yields `MyCases_Test`) and defaults to
//  `StanCases_Test` otherwise.
//
//  Across runs, the `_Test` dir is left populated so cmdstan binaries
//  / compiled `.stan` artifacts survive — make-style staleness checks
//  skip the rebuild on subsequent invocations. To exercise the
//  "empty StanCases_Test" contract (every test must self-bootstrap its
//  prerequisites), wipe with `rm -rf ~/Documents/StanCases_Test`
//  before the run.
//

import Foundation
@testable import SwiftStan

enum TestCaseRootBootstrap {
  /// Touched from every `@Suite` struct's `init()`. The closure runs
  /// exactly once thanks to Swift's lazy-static-let semantics.
    static let install: Void = {
    let documents = FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)[0]
    let baseName: String
    if let env = ProcessInfo.processInfo.environment["STAN_CASES"],
       !env.isEmpty {
      // `$STAN_CASES` might be an absolute path (e.g.
      // `/Users/rob/Documents/StanCases`) or a bare dir name; use the
      // last path component as the redirect basename either way.
      baseName = (env as NSString).lastPathComponent
    } else {
      baseName = "StanCases"
    }
    let fm = FileManager.default
    // Default to ~/tmp (no TCC consent required, works from both `swift test`
    // and Xcode's test runner). When $STAN_CASES is explicitly set, honour it
    // — the user has already made the directory writable.
    if ProcessInfo.processInfo.environment["STAN_CASES"] != nil {
      caseRootOverride = documents
        .appendingPathComponent("\(baseName)_Test", isDirectory: true)
    } else {
      caseRootOverride = fm.temporaryDirectory
        .appendingPathComponent("\(baseName)_Test", isDirectory: true)
    }
    return ()
  }()
}
