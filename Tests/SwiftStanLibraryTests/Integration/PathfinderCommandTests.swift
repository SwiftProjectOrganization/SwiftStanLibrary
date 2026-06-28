//
//  PathfinderCommandTests.swift
//  StanTests
//
//  Direct tests for `stanPathfinder(...)`. Same happy/failure pattern
//  as the sample command tests.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("Stan pathfinder command tests", .enabled(if: ProcessInfo.processInfo.environment["CMDSTAN"] != nil, "Set $CMDSTAN to run integration tests"))
struct PathfinderCommandTests {
  init() { _ = TestCaseRootBootstrap.install }


  static let cmdstan: String = {
    if let env = ProcessInfo.processInfo.environment["CMDSTAN"], !env.isEmpty {
      return env
    }
    return ProcessInfo.processInfo.environment["CMDSTAN"] ?? ""
  }()

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

  @Test func stanPathfinderSucceedsOnCompleteData() throws {
    let model = "pathfinder_ok_test"
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

    let result = stanPathfinder(dirUrl: paths.results,
                                modelName: model,
                                cmdstan: Self.cmdstan,
                                verbose: false)
    #expect(result.1.isEmpty,
            "stanPathfinder should succeed on valid data; got error: \(result.1)")

    let outputURL = paths.results.appendingPathComponent("\(model)_pathfinder.csv")
    #expect(FileManager.default.fileExists(atPath: outputURL.path),
            "pathfinder output CSV should exist at \(outputURL.path)")
  }

  @Test func stanPathfinderFailsWhenDataMissingDeclaredVariable() throws {
    let model = "pathfinder_missing_y_test"
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

    let badJSON = #"{"N": 5}"#
    let dataURL = paths.results.appendingPathComponent("\(model).data.json")
    try badJSON.write(to: dataURL, atomically: true, encoding: .utf8)

    let result = stanPathfinder(dirUrl: paths.results,
                                modelName: model,
                                cmdstan: Self.cmdstan,
                                verbose: false)
    #expect(!result.1.isEmpty,
            "stanPathfinder should return an error when data is missing a declared variable")
    #expect(result.1.contains("y"),
            "Error should reference the missing variable; got: \(result.1)")
  }
}
