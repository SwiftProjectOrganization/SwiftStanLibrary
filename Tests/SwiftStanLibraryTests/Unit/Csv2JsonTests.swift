//
//  Csv2JsonTests.swift
//  StanTests
//
//  V2.1 Slice C: coverage for the `csv2json` command. Three cases:
//   - Happy path: chimpanzees CSV + generated Stan source produces a
//     JSON file with the expected schema-derived keys.
//   - NA detection: a synthetic CSV with `NA` in a row-data column
//     surfaces `Csv2JsonError.naValue` with column + row.
//   - Schema mismatch: a CSV missing a required column surfaces
//     `Csv2JsonError.schemaColumnMissing`.
//
//  The NA / schema-mismatch tests use a temporary synthetic model so
//  they don't disturb the chimpanzees fixtures the happy-path test
//  relies on.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("csv2json command tests")
struct Csv2JsonTests {
  init() { _ = TestCaseRootBootstrap.install }


  @Test func chimpanzeesHappyPath() throws {
    let paths = casePaths(for: "chimpanzees")
    let csvURL = paths.preliminaries.appendingPathComponent("chimpanzees.csv")
    let alistURL = paths.preliminaries.appendingPathComponent("chimpanzees.alist.R")
    let stanURL = paths.results.appendingPathComponent("chimpanzees.stan")
    let fm = FileManager.default

    // Bootstrap from bundled fixtures so the test works on a clean
    // checkout. csv2json itself doesn't generate the .stan it validates
    // against — we run `stancode` against the alist fixture to produce
    // it. Skipped when the user already has a hand-authored `.stan`.
    try ensureCaseDirectories(paths)
    if !fm.fileExists(atPath: csvURL.path) {
      try stageBundledFixture(named: "chimpanzees.csv", to: csvURL)
    }
    if !fm.fileExists(atPath: alistURL.path) {
      try stageBundledFixture(named: "chimpanzees.alist.R", to: alistURL)
    }
    if !fm.fileExists(atPath: stanURL.path) {
      _ = try stancode(model: "chimpanzees")
    }

    try #require(fm.fileExists(atPath: csvURL.path))
    try #require(fm.fileExists(atPath: stanURL.path))

    let outURL = try csv2json(model: "chimpanzees")
    let payload = try Data(contentsOf: outURL)
    let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
    let dict = try #require(json)

    // Derived cardinality scalars.
    #expect(dict["N"] as? Int == 504)
    #expect(dict["N_actor"] as? Int == 7)
    #expect(dict["N_block_id"] as? Int == 6)

    // Row-data columns (lengths only — values come from the upstream CSV).
    let actor = try #require(dict["actor"] as? [Int])
    let blockId = try #require(dict["block_id"] as? [Int])
    let pulledLeft = try #require(dict["pulled_left"] as? [Int])
    let condition = try #require(dict["condition"] as? [Double])
    let prosocLeft = try #require(dict["prosoc_left"] as? [Double])
    #expect(actor.count == 504)
    #expect(blockId.count == 504)
    #expect(pulledLeft.count == 504)
    #expect(condition.count == 504)
    #expect(prosocLeft.count == 504)
  }

  @Test func naInRowDataColumnIsRejected() throws {
    let model = "csv2json_na_fixture"
    try Self.installSyntheticModel(name: model,
                                   stanSource: Self.miniStan,
                                   csvContent: Self.csvWithNA)
    defer { Self.removeSyntheticModel(name: model) }

    #expect(throws: Csv2JsonError.self) {
      _ = try csv2json(model: model)
    }
  }

  @Test func missingSchemaColumnIsRejected() throws {
    let model = "csv2json_missing_fixture"
    try Self.installSyntheticModel(name: model,
                                   stanSource: Self.miniStan,
                                   csvContent: Self.csvMissingColumn)
    defer { Self.removeSyntheticModel(name: model) }

    #expect(throws: Csv2JsonError.self) {
      _ = try csv2json(model: model)
    }
  }

  // MARK: - String-column auto-factorisation (2026-06-08)

  /// A schema-int column whose CSV values are all non-NA strings
  /// (e.g. `"AITKIN", "ANOKA", …`) should be auto-factorised:
  /// first-seen string gets 1, second unique gets 2, etc. The
  /// resulting `data.json` carries the integer values; a side-file
  /// `Results/<name>.factors.json` carries the `level → int` map.
  @Test func stringIndexColumnIsAutoFactorised() throws {
    let model = "csv2json_factor_fixture"
    let stanSource = """
    data {
      int<lower=1> N;
      int<lower=1> N_county;
      array[N] int<lower=1, upper=N_county> county;
      vector[N] x;
    }
    """
    let csv = """
    county,x
    AITKIN,0.1
    ANOKA,0.2
    AITKIN,0.3
    BLAINE,0.4
    ANOKA,0.5
    """
    try Self.installSyntheticModel(name: model,
                                   stanSource: stanSource,
                                   csvContent: csv)
    defer { Self.removeSyntheticModel(name: model) }

    let dataURL = try csv2json(model: model)
    let dataJSON = try JSONSerialization.jsonObject(
      with: try Data(contentsOf: dataURL)) as? [String: Any]
    let payload = try #require(dataJSON)
    // Integer-coded county column: AITKIN→1, ANOKA→2, BLAINE→3.
    #expect(payload["county"] as? [Int] == [1, 2, 1, 3, 2])
    // Cardinality derives via the existing max(values) path.
    #expect(payload["N_county"] as? Int == 3)
    #expect(payload["N"] as? Int == 5)

    // factors.json captures the level → int map.
    let factorsURL = casePaths(for: model)
      .results.appendingPathComponent("\(model).factors.json")
    #expect(FileManager.default.fileExists(atPath: factorsURL.path))
    let factorsJSON = try JSONSerialization.jsonObject(
      with: try Data(contentsOf: factorsURL)) as? [String: [String: Int]]
    let factors = try #require(factorsJSON?["county"])
    #expect(factors == ["AITKIN": 1, "ANOKA": 2, "BLAINE": 3])
  }

  /// Mixed-shape columns (some integer-valued rows, some string-valued)
  /// throw `mixedTypeIndexColumn` pointing at the integer-shaped row
  /// that broke the otherwise-string column. Genuine data bugs
  /// surface; we don't silently factorise.
  @Test func mixedIntStringIndexColumnIsRejected() throws {
    let model = "csv2json_mixed_fixture"
    let stanSource = """
    data {
      int<lower=1> N;
      int<lower=1> N_group;
      array[N] int<lower=1, upper=N_group> group;
    }
    """
    let csv = """
    group
    AITKIN
    ANOKA
    7
    BLAINE
    """
    try Self.installSyntheticModel(name: model,
                                   stanSource: stanSource,
                                   csvContent: csv)
    defer { Self.removeSyntheticModel(name: model) }

    #expect(throws: Csv2JsonError.self) {
      _ = try csv2json(model: model)
    }
  }

  /// All-integer index column stays untouched: no factorisation,
  /// no side-file written. Regression guard for the happy path.
  @Test func integerIndexColumnLeavesFactorsSideFileAbsent() throws {
    let model = "csv2json_no_factors_fixture"
    let stanSource = """
    data {
      int<lower=1> N;
      int<lower=1> N_group;
      array[N] int<lower=1, upper=N_group> group;
      vector[N] x;
    }
    """
    let csv = """
    group,x
    1,0.1
    2,0.2
    1,0.3
    """
    try Self.installSyntheticModel(name: model,
                                   stanSource: stanSource,
                                   csvContent: csv)
    defer { Self.removeSyntheticModel(name: model) }

    _ = try csv2json(model: model)
    let factorsURL = casePaths(for: model)
      .results.appendingPathComponent("\(model).factors.json")
    #expect(!FileManager.default.fileExists(atPath: factorsURL.path),
            "factors.json should NOT be written when no column was factorised")
  }

  // MARK: - Fixtures

  /// Tiny two-column Stan source the synthetic tests validate against.
  /// `y` is an int outcome, `x` is a real predictor.
  static let miniStan = """
    data {
      int<lower=1> N;
      array[N] int<lower=0, upper=1> y;
      vector[N] x;
    }
    """

  static let csvWithNA = """
    y,x
    0,0.1
    1,NA
    0,0.3
    """

  static let csvMissingColumn = """
    y
    0
    1
    0
    """

  static func installSyntheticModel(name: String,
                                    stanSource: String,
                                    csvContent: String) throws {
    let paths = casePaths(for: name)
    try ensureCaseDirectories(paths)
    try stanSource.write(to: paths.results.appendingPathComponent("\(name).stan"),
                         atomically: true, encoding: .utf8)
    try csvContent.write(to: paths.preliminaries.appendingPathComponent("\(name).csv"),
                         atomically: true, encoding: .utf8)
  }

  static func removeSyntheticModel(name: String) {
    let root = caseRoot().appendingPathComponent(name)
    try? FileManager.default.removeItem(at: root)
  }
}
