//
//  CompileCommandTests.swift
//  StanTests
//
//  Direct tests for `stanCompile(...)`. Compile shells out to
//  `make -C <cmdstan> <modelPath>`, which propagates stanc's parse
//  errors via a non-zero exit. swiftSyncFileExec now surfaces those.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("Stan compile command tests", .enabled(if: ProcessInfo.processInfo.environment["CMDSTAN"] != nil, "Set $CMDSTAN to run integration tests"))
struct CompileCommandTests {
  init() { _ = TestCaseRootBootstrap.install }


  static let cmdstan: String = {
    if let env = ProcessInfo.processInfo.environment["CMDSTAN"], !env.isEmpty {
      return env
    }
    return ProcessInfo.processInfo.environment["CMDSTAN"] ?? ""
  }()

  /// Compile a syntactically valid minimal Bernoulli model. Expects
  /// stanCompile to succeed and the binary to exist on disk.
  @Test func stanCompileSucceedsOnValidSource() throws {
    let model = "compile_ok_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)

    let validSource = """
    data {
      int<lower=1> N;
      array[N] int<lower=0, upper=1> y;
    }
    parameters {
      real<lower=0, upper=1> theta;
    }
    model {
      theta ~ beta(1, 1);
      y ~ bernoulli(theta);
    }
    """
    let stanURL = paths.results.appendingPathComponent("\(model).stan")
    try validSource.write(to: stanURL, atomically: true, encoding: .utf8)

    let result = stanCompile(dirUrl: paths.results,
                             modelName: model,
                             cmdstan: Self.cmdstan,
                             verbose: false)
    #expect(result.1.isEmpty,
            "stanCompile should succeed; got error: \(result.1)")

    let binaryURL = paths.results.appendingPathComponent(model)
    #expect(FileManager.default.fileExists(atPath: binaryURL.path),
            "compiled binary should exist at \(binaryURL.path)")
  }

  /// stanc rejects malformed Stan source. Pre-fix the wrapper claimed
  /// success regardless of stanc's exit code; this test guards against
  /// that regressing.
  @Test func stanCompileFailsOnInvalidSource() throws {
    let model = "compile_bad_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)

    // Missing semicolon and an undeclared identifier — stanc reports
    // a parse error.
    let invalidSource = """
    data {
      int<lower=1> N
      this is not valid stan
    }
    """
    let stanURL = paths.results.appendingPathComponent("\(model).stan")
    try invalidSource.write(to: stanURL, atomically: true, encoding: .utf8)

    // Make sure no leftover binary from a previous run masks failure.
    let binaryURL = paths.results.appendingPathComponent(model)
    try? FileManager.default.removeItem(at: binaryURL)

    let result = stanCompile(dirUrl: paths.results,
                             modelName: model,
                             cmdstan: Self.cmdstan,
                             verbose: false)
    #expect(!result.1.isEmpty,
            "stanCompile should return an error on invalid Stan source")
  }
}
