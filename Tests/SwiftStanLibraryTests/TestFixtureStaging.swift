//
//  TestFixtureStaging.swift
//  SwiftStanTests
//
//  Shared helper for staging bundled `Tests/TestDataFiles/`
//  fixtures into per-model case dirs under `~/Documents/<STAN_CASES>/`.
//  Used by tests that depend on the canonical chimpanzees / howell
//  inputs and otherwise fail when run from a clean checkout (empty
//  StanCases dir).
//

import Foundation
import Testing

enum TestFixtureStagingError: Error, CustomStringConvertible {
  case bundledFixtureMissing(String)
  var description: String {
    switch self {
    case .bundledFixtureMissing(let name):
      return "bundled fixture `\(name)` missing — check Tests/TestDataFiles/ and Package.swift `resources:`"
    }
  }
}

/// Copy a fixture bundled under the test target's `TestDataFiles/`
/// resource directory into the destination URL. Overwrites if a stale
/// copy is already present. Throws if the resource can't be located —
/// indicates the file was renamed or not declared in `resources:`.
///
/// Race-safe under Swift Testing parallelism: when two tests stage the
/// same fixture to the same destination simultaneously, the second
/// (loser) catches the cocoa "file exists" error from `copyItem` and
/// returns — both tests want identical bytes in the same path, so the
/// winner's copy is fine.
func stageBundledFixture(named name: String, to dest: URL) throws {
  guard let src = Bundle.module
    .url(forResource: name, withExtension: nil, subdirectory: "Resources")
  else {
    throw TestFixtureStagingError.bundledFixtureMissing(name)
  }
  let fm = FileManager.default
  try fm.createDirectory(at: dest.deletingLastPathComponent(),
                         withIntermediateDirectories: true)
  try? fm.removeItem(at: dest)
  do {
    try fm.copyItem(at: src, to: dest)
  } catch let error as NSError
    where error.domain == NSCocoaErrorDomain
       && error.code == NSFileWriteFileExistsError {
    // Another test won the race and finished copying the same fixture
    // between our `removeItem` and `copyItem`. Content is identical
    // either way — let the winner stand.
    return
  }
}
