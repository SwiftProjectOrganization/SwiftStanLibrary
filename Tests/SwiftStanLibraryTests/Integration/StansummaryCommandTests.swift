//
//  StansummaryCommandTests.swift
//  StanTests
//
//  Direct tests for `stanSummary(...)` — the wrapper around cmdstan's
//  `stansummary` binary. Reads four `<name>_output_<i>.csv` chain
//  files and writes a `<name>_stansummary.csv` aggregate. Happy
//  path: run a tiny sample then summarise. Failure path: invoke with
//  no chain files present — cmdstan stansummary exits non-zero and
//  the wrapper surfaces it.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("Stan stansummary command tests", .enabled(if: ProcessInfo.processInfo.environment["CMDSTAN"] != nil, "Set $CMDSTAN to run integration tests"))
struct StansummaryCommandTests {
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

  /// Compile + sample so the four chain outputs exist, then summarise.
  /// Asserts the raw `<name>_stansummary.csv` lands.
  @Test func stanSummarySucceedsOnExistingChains() throws {
    let model = "stansummary_ok_test"
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

    let sampleResult = stanSample(dirUrl: paths.results,
                                  modelName: model,
                                  arguments: ["num_chains=4", "num_samples=200"],
                                  cmdstan: Self.cmdstan,
                                  verbose: false)
    try #require(sampleResult.1.isEmpty,
                 "stanSample error: \(sampleResult.1)")

    let result = stanSummary(dirUrl: paths.results,
                             modelName: model,
                             cmdstan: Self.cmdstan)
    #expect(result.1.isEmpty,
            "stanSummary should succeed; got error: \(result.1)")

    let summaryURL = paths.results.appendingPathComponent("\(model)_stansummary.csv")
    #expect(FileManager.default.fileExists(atPath: summaryURL.path),
            "stansummary CSV should exist at \(summaryURL.path)")
  }

  /// 2026-06-02: `chainOutputFiles` globs `<name>_output*.csv` and
  /// sorts numerically so chain 10+ doesn't reorder ahead of chain 2.
  /// Also matches the `_output.csv` (no suffix) form cmdstan writes
  /// for single-chain runs.
  @Test func chainOutputFilesSortsNumericallyAcrossDoubleDigits() throws {
    let model = "chain_glob_unit_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)
    let fm = FileManager.default
    defer {
      try? fm.removeItem(at: caseRoot().appendingPathComponent(model))
    }

    // Wipe any leftover entries from a prior run.
    for entry in (try? fm.contentsOfDirectory(atPath: paths.results.path)) ?? [] {
      try? fm.removeItem(at: paths.results.appendingPathComponent(entry))
    }
    // Touch 12 fake chain files plus a noise file that must be ignored.
    for n in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] {
      let url = paths.results.appendingPathComponent("\(model)_output_\(n).csv")
      try "".write(to: url, atomically: true, encoding: .utf8)
    }
    let noise = paths.results.appendingPathComponent("\(model)_output_unrelated.txt")
    try "".write(to: noise, atomically: true, encoding: .utf8)

    let chains = chainOutputFiles(dirUrl: paths.results, modelName: model)
    let names = chains.map { $0.lastPathComponent }
    #expect(names == (1...12).map { "\(model)_output_\($0).csv" },
            "chains should be ordered 1, 2, …, 12; got \(names)")
  }

  /// `_output.csv` (no suffix) — the single-chain form — is included.
  @Test func chainOutputFilesIncludesSingleChainForm() throws {
    let model = "chain_glob_single_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)
    let fm = FileManager.default
    defer {
      try? fm.removeItem(at: caseRoot().appendingPathComponent(model))
    }

    for entry in (try? fm.contentsOfDirectory(atPath: paths.results.path)) ?? [] {
      try? fm.removeItem(at: paths.results.appendingPathComponent(entry))
    }
    let single = paths.results.appendingPathComponent("\(model)_output.csv")
    try "".write(to: single, atomically: true, encoding: .utf8)

    let chains = chainOutputFiles(dirUrl: paths.results, modelName: model)
    #expect(chains.map { $0.lastPathComponent } == ["\(model)_output.csv"])
  }

  /// With no chain outputs on disk, cmdstan's stansummary exits
  /// non-zero. The wrapper now surfaces that as a non-empty error.
  @Test func stanSummaryFailsWhenChainsMissing() throws {
    let model = "stansummary_no_chains_test"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)

    // Remove any leftover chain outputs from a previous run.
    let fm = FileManager.default
    for i in 1...4 {
      let url = paths.results.appendingPathComponent("\(model)_output_\(i).csv")
      try? fm.removeItem(at: url)
    }

    let result = stanSummary(dirUrl: paths.results,
                             modelName: model,
                             cmdstan: Self.cmdstan)
    #expect(!result.1.isEmpty,
            "stanSummary should return an error when chain outputs are missing")
  }
}
