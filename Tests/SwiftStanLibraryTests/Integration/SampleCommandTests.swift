//
//  SampleCommandTests.swift
//  StanTests
//
//  Direct tests for `stanSample(...)` — the layer that runs the
//  compiled cmdstan binary against a `.data.json` and surfaces the
//  result tuple. The higher-level `sample(...)` command wraps this
//  with `exit(...)` calls and isn't directly testable.
//
//  Covers the swiftSyncFileExec error-propagation fix: cmdstan's
//  non-zero exit + stderr now surface as a non-empty `result.1`,
//  where previously every invocation was reported as a success.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("Stan sample command tests", .enabled(if: ProcessInfo.processInfo.environment["CMDSTAN"] != nil, "Set $CMDSTAN to run integration tests"))
struct SampleCommandTests {
  init() { _ = TestCaseRootBootstrap.install }


  static let cmdstan: String = {
    if let env = ProcessInfo.processInfo.environment["CMDSTAN"], !env.isEmpty {
      return env
    }
    return ProcessInfo.processInfo.environment["CMDSTAN"] ?? ""
  }()

  /// Minimal Bernoulli .stan source used by both tests. Declares `N`
  /// and `y`; the failure path drops `y` from the data JSON.
  static let bernoulliStanSource = """
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

  /// stanSample's happy path. Compiles the minimal Bernoulli model,
  /// writes complete data, then samples. Asserts the result tuple
  /// reports success.
  @Test func stanSampleSucceedsOnCompleteData() throws {
    let model = "sample_ok_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)

    let stanURL = paths.results.appendingPathComponent("\(model).stan")
    try Self.bernoulliStanSource.write(to: stanURL,
                                       atomically: true, encoding: .utf8)

    let compileResult = stanCompile(dirUrl: paths.results,
                                    modelName: model,
                                    cmdstan: Self.cmdstan,
                                    verbose: false)
    try #require(compileResult.1.isEmpty,
                 "stanCompile error: \(compileResult.1)")

    let goodJSON = #"{"N": 5, "y": [0, 1, 0, 1, 1]}"#
    let dataURL = paths.results.appendingPathComponent("\(model).data.json")
    try goodJSON.write(to: dataURL, atomically: true, encoding: .utf8)

    let result = stanSample(dirUrl: paths.results,
                            modelName: model,
                            arguments: ["num_chains=1", "num_samples=200"],
                            cmdstan: Self.cmdstan,
                            verbose: false)
    #expect(result.1.isEmpty,
            "stanSample should succeed on valid data; got error: \(result.1)")
    #expect(result.0.contains("completed successfully"),
            "stanSample should report completion; got: \(result.0)")
  }

  /// Regression test for the swiftSyncFileExec fix: a model that
  /// declares `y` paired with a data JSON that omits it should be
  /// reported as an error, not silently as success. cmdstan exits
  /// non-zero and prints `Variable y is not in input data.` to stderr;
  /// the Swift wrapper now surfaces both.
  @Test func stanSampleFailsWhenDataMissingDeclaredVariable() throws {
    let model = "sample_missing_y_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)

    let stanURL = paths.results.appendingPathComponent("\(model).stan")
    try Self.bernoulliStanSource.write(to: stanURL,
                                       atomically: true, encoding: .utf8)

    let compileResult = stanCompile(dirUrl: paths.results,
                                    modelName: model,
                                    cmdstan: Self.cmdstan,
                                    verbose: false)
    try #require(compileResult.1.isEmpty,
                 "stanCompile error: \(compileResult.1)")

    // Defines N but not y — Stan rejects at runtime with a clear
    // diagnostic on stderr.
    let badJSON = #"{"N": 5}"#
    let dataURL = paths.results.appendingPathComponent("\(model).data.json")
    try badJSON.write(to: dataURL, atomically: true, encoding: .utf8)

    let result = stanSample(dirUrl: paths.results,
                            modelName: model,
                            arguments: ["num_chains=1", "num_samples=200"],
                            cmdstan: Self.cmdstan,
                            verbose: false)
    #expect(!result.1.isEmpty,
            "stanSample should return an error when data is missing a declared variable")
    // Diagnostic should mention the missing variable explicitly.
    #expect(result.1.contains("y"),
            "Error should reference the missing variable; got: \(result.1)")
  }
}
