//
//  RunInfoChainsTests.swift
//  SwiftStanTests
//
//  Unit coverage for `chainsFromRunInfo(dirUrl:modelName:)` in
//  `Methods/RunStanSummary.swift`. Verifies the runinfo-first /
//  glob-backup contract for stansummary and getSampleResult without
//  paying the cost of an end-to-end cmdstan sample — each test
//  synthesises a `<name>.config.json` plus matching chain CSV
//  stubs in a per-test case dir, exercises the helper, and asserts the
//  returned URL list (or nil).
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("chainsFromRunInfo tests")
struct RunInfoChainsTests {
  init() { _ = TestCaseRootBootstrap.install }


  /// Write a minimal `<name>.config.json` with the given
  /// num_chains + starting id under method=sample. All non-essential
  /// nested fields (`adapt`, `algorithm`, …) carry default-ish values
  /// just to satisfy the `Decodable` shape — the helper only reads
  /// `method.value`, `method.sample.num_chains`, and the top-level
  /// `id`, so the rest never gets exercised.
  private func writeSampleConfig(dirUrl: URL,
                                 modelName: String,
                                 numChains: Int,
                                 id: Int = 1) throws {
    let json = """
    {
      "stan_major_version": "2",
      "stan_minor_version": "38",
      "stan_patch_version": "0",
      "model_name": "\(modelName)_model",
      "start_datetime": "2026-06-06 00:00:00 UTC",
      "method": {
        "value": "sample",
        "sample": {
          "num_samples": 1000,
          "num_warmup": 1000,
          "save_warmup": false,
          "thin": 1,
          "adapt": {
            "engaged": true, "gamma": 0.05, "delta": 0.8, "kappa": 0.75,
            "t0": 10, "init_buffer": 75, "term_buffer": 50, "window": 25,
            "save_metric": false
          },
          "algorithm": {
            "value": "hmc",
            "hmc": {
              "engine": { "value": "nuts", "nuts": { "max_depth": 10 } },
              "metric": { "value": "diag_e" },
              "metric_file": "", "stepsize": 1, "stepsize_jitter": 0
            }
          },
          "num_chains": \(numChains)
        }
      },
      "id": \(id),
      "data": { "file": "\(modelName).data.json" },
      "init": "2",
      "random": { "seed": -1 },
      "output": {
        "file": "\(modelName)_output.csv",
        "diagnostic_file": "", "refresh": 100, "sig_figs": 8,
        "profile_file": "profile.csv", "save_cmdstan_config": true
      },
      "num_threads": 1,
      "mpi_enabled": false,
      "stanc_version": "stanc3 v2.38.0",
      "stancflags": ""
    }
    """
    let url = dirUrl.appendingPathComponent("\(modelName).config.json")
    try json.write(to: url, atomically: true, encoding: .utf8)
  }

  /// Touch an empty chain output file at `<name>_output_<id>.csv` (or
  /// `<name>_output.csv` when `id == nil` for single-chain runs).
  private func touchChain(dirUrl: URL,
                          modelName: String,
                          id: Int?) throws {
    let name = id.map { "\(modelName)_output_\($0).csv" }
            ?? "\(modelName)_output.csv"
    try "".write(to: dirUrl.appendingPathComponent(name),
                 atomically: true, encoding: .utf8)
  }

  /// Per-test scratch dir under the OS temp dir; auto-cleaned at the
  /// end via deferred cleanup in each test.
  private func makeScratchDir(label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("RunInfoChainsTests-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url,
                                            withIntermediateDirectories: true)
    return url
  }

  @Test func positiveAllChainsPresentReturnsIdOrder() throws {
    let dir = try makeScratchDir(label: "positive")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_pos"
    try writeSampleConfig(dirUrl: dir, modelName: model, numChains: 4)
    for i in 1...4 { try touchChain(dirUrl: dir, modelName: model, id: i) }

    let result = try #require(chainsFromRunInfo(dirUrl: dir, modelName: model))
    #expect(result.count == 4)
    let names = result.map { $0.lastPathComponent }
    #expect(names == [
      "\(model)_output_1.csv",
      "\(model)_output_2.csv",
      "\(model)_output_3.csv",
      "\(model)_output_4.csv",
    ])
  }

  @Test func singleChainUsesNoSuffixForm() throws {
    let dir = try makeScratchDir(label: "single")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_single"
    try writeSampleConfig(dirUrl: dir, modelName: model, numChains: 1)
    try touchChain(dirUrl: dir, modelName: model, id: nil)

    let result = try #require(chainsFromRunInfo(dirUrl: dir, modelName: model))
    #expect(result.count == 1)
    #expect(result[0].lastPathComponent == "\(model)_output.csv")
  }

  @Test func partialRunReturnsAvailableSubset() throws {
    let dir = try makeScratchDir(label: "partial")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_partial"
    try writeSampleConfig(dirUrl: dir, modelName: model, numChains: 4)
    // Only chains 1, 2, 4 made it to disk — chain 3 diverged.
    for i in [1, 2, 4] { try touchChain(dirUrl: dir, modelName: model, id: i) }

    let result = try #require(chainsFromRunInfo(dirUrl: dir, modelName: model))
    let names = result.map { $0.lastPathComponent }
    #expect(names == [
      "\(model)_output_1.csv",
      "\(model)_output_2.csv",
      "\(model)_output_4.csv",
    ])
  }

  @Test func honoursChainIdOffset() throws {
    let dir = try makeScratchDir(label: "offset")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_offset"
    // Batched run: chains 5, 6, 7 (id offset of 5, num_chains 3).
    try writeSampleConfig(dirUrl: dir, modelName: model, numChains: 3, id: 5)
    for i in [5, 6, 7] { try touchChain(dirUrl: dir, modelName: model, id: i) }
    // Decoy: a stray chain-1 file from a previous run that shouldn't
    // be picked up by the runinfo path.
    try touchChain(dirUrl: dir, modelName: model, id: 1)

    let result = try #require(chainsFromRunInfo(dirUrl: dir, modelName: model))
    let names = result.map { $0.lastPathComponent }
    #expect(names == [
      "\(model)_output_5.csv",
      "\(model)_output_6.csv",
      "\(model)_output_7.csv",
    ])
    #expect(!names.contains("\(model)_output_1.csv"),
            "id-offset run shouldn't include unrelated chain 1")
  }

  @Test func missingConfigReturnsNil() throws {
    let dir = try makeScratchDir(label: "noconfig")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_noconfig"
    // Chain files exist but no config — caller should fall back to glob.
    for i in 1...2 { try touchChain(dirUrl: dir, modelName: model, id: i) }

    #expect(chainsFromRunInfo(dirUrl: dir, modelName: model) == nil)
  }

  @Test func nonSampleMethodReturnsNil() throws {
    let dir = try makeScratchDir(label: "optimize")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_optimize"
    // Synthesise an `optimize`-method config — chains don't apply.
    let json = """
    {
      "stan_major_version": "2", "stan_minor_version": "38",
      "stan_patch_version": "0", "model_name": "\(model)_model",
      "start_datetime": "2026-06-06 00:00:00 UTC",
      "method": { "value": "optimize", "optimize": {} },
      "id": 1, "data": { "file": "x" }, "init": "2",
      "random": { "seed": -1 },
      "output": {
        "file": "x", "diagnostic_file": "", "refresh": 100, "sig_figs": 8,
        "profile_file": "", "save_cmdstan_config": true
      },
      "num_threads": 1, "mpi_enabled": false,
      "stanc_version": "stanc3 v2.38.0", "stancflags": ""
    }
    """
    try json.write(
      to: dir.appendingPathComponent("\(model).config.json"),
      atomically: true, encoding: .utf8)

    #expect(chainsFromRunInfo(dirUrl: dir, modelName: model) == nil)
  }

  @Test func noChainFilesOnDiskReturnsNil() throws {
    let dir = try makeScratchDir(label: "noChains")
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = "ric_no_chains"
    // Config promises 4 chains, but no chain files were ever written.
    // Returning nil lets the caller's glob path surface the right
    // "no chains found" error rather than an empty list silently.
    try writeSampleConfig(dirUrl: dir, modelName: model, numChains: 4)

    #expect(chainsFromRunInfo(dirUrl: dir, modelName: model) == nil)
  }
}
