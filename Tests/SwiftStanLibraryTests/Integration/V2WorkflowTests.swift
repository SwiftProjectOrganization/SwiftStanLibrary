//
//  V2WorkflowTests.swift
//  StanTests
//
//  V2.1 Slice G: end-to-end coverage for the file-based ulamPipeline.
//  Exercises `dsl2stan → csv2json → compile → sample` chained together
//  against the chimpanzees fixtures. The individual command suites
//  (`Dsl2StanTests`, `Csv2JsonTests`) cover each step in isolation —
//  this suite proves they compose into a working workflow.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("V2.1 pipeline workflow tests", .enabled(if: ProcessInfo.processInfo.environment["CMDSTAN"] != nil, "Set $CMDSTAN to run integration tests"))
struct V2WorkflowTests {
  init() { _ = TestCaseRootBootstrap.install }


  static let cmdstan: String = {
    if let env = ProcessInfo.processInfo.environment["CMDSTAN"], !env.isEmpty {
      return env
    }
    return ProcessInfo.processInfo.environment["CMDSTAN"] ?? ""
  }()

  /// Drives the four-step file pipeline against chimpanzees. Both inputs
  /// (Preliminaries/Chimpanzees.ulam.swift + chimpanzees.csv) exist from
  /// Slice B's migration; the pipeline should produce a fresh .stan,
  /// .data.json, cmdstan binary, and chain CSVs in Results/.
  @Test func chimpanzeesPipelineEndToEnd() throws {
    let paths = casePaths(for: "chimpanzees")
    let fm = FileManager.default
    let csvURL = paths.preliminaries.appendingPathComponent("chimpanzees.csv")
    let driverURL = paths.preliminaries.appendingPathComponent("Chimpanzees.ulam.swift")
    let alistURL = paths.preliminaries.appendingPathComponent("chimpanzees.alist.R")

    // Stage bundled fixtures so a fresh checkout with an empty
    // `~/Documents/<STAN_CASES>/` doesn't fail the pre-checks. Stages
    // all three (csv, driver, alist) to match the user's typical local
    // layout — `ulamPipeline` then prefers the alist (stancode fast
    // path) over the smoke driver.
    try fm.createDirectory(at: paths.preliminaries,
                           withIntermediateDirectories: true)
    if !fm.fileExists(atPath: csvURL.path) {
      try stageBundledFixture(named: "chimpanzees.csv", to: csvURL)
    }
    if !fm.fileExists(atPath: driverURL.path) {
      try stageBundledFixture(named: "Chimpanzees.ulam.swift", to: driverURL)
    }
    if !fm.fileExists(atPath: alistURL.path) {
      try stageBundledFixture(named: "chimpanzees.alist.R", to: alistURL)
    }

    try #require(fm.fileExists(atPath: driverURL.path))
    try #require(fm.fileExists(atPath: csvURL.path))

    let result = ulamPipeline(model: "chimpanzees",
                              cmdstan: Self.cmdstan)
    try #require(result.1.isEmpty,
                 "ulamPipeline returned an error: \(result.1)")

    let stan = paths.results.appendingPathComponent("chimpanzees.stan")
    let data = paths.results.appendingPathComponent("chimpanzees.data.json")
    let summary = paths.results.appendingPathComponent("chimpanzees.stansummary.csv")
    #expect(fm.fileExists(atPath: stan.path))
    #expect(fm.fileExists(atPath: data.path))
    #expect(fm.fileExists(atPath: summary.path),
            "stansummary missing — sample step didn't complete")
  }

  /// Howell adult-heights model (McElreath m4.1): a single Gaussian
  /// likelihood with `mu ~ Normal(178, 20)` and `sigma ~ Uniform(0, 50)`
  /// over Howell1.csv pre-filtered to adults. The smallest non-trivial
  /// pipeline case — exercises dsl2stan ← Howell.ulam.swift OR stancode
  /// ← howell.alist.R, csv2json, compile, sample, and the post-sample
  /// stansummary cleanup.
  ///
  /// 2026-06-02: convergence is now asserted via R-hat < 1.05 on `mu`
  /// and `sigma`. The pipeline takes the alist fast path (alist→stancode
  /// is in-process; the v1 alist surface has no `start=` syntax for
  /// inits yet), so the test pre-stages `Results/howell.init.json` to
  /// simulate the hand-crafted file path users take today. The
  /// `StanSample` auto-detection at `Methods/StanSample.swift:23-29`
  /// finds the file and prepends `init=<path>` to the cmdstan argv —
  /// without this, mu's U(-2, 2) random init can't climb to the
  /// posterior at ~155 cm and the sampler diverges. Companion fixture
  /// `Howell.ulam.swift` declares the same inits via `Inits([:])` for
  /// the smoke-driver / dsl2stan path; that path is exercised by the
  /// existing `smokeDriverRoundTripsToGolden` test plus the unit
  /// coverage of `InitMarshaller`.
  @Test func howellPipelineEndToEnd() throws {
    let paths = casePaths(for: "howell")
    let fm = FileManager.default
    let csvURL = paths.preliminaries.appendingPathComponent("howell.csv")
    let alistURL = paths.preliminaries.appendingPathComponent("howell.alist.R")
    let driverURL = paths.preliminaries.appendingPathComponent("Howell.ulam.swift")

    // Stage bundled fixtures into the case dir so a fresh checkout with
    // an empty `~/Documents/<STAN_CASES>/` doesn't fail the pre-checks.
    // Skipped if either file already exists (e.g. the user has a
    // hand-authored `Howell.ulam.swift` in place).
    try fm.createDirectory(at: paths.preliminaries,
                           withIntermediateDirectories: true)
    if !fm.fileExists(atPath: csvURL.path) {
      try stageBundledFixture(named: "howell.csv", to: csvURL)
    }
    if !fm.fileExists(atPath: alistURL.path)
        && !fm.fileExists(atPath: driverURL.path) {
      try stageBundledFixture(named: "howell.alist.R", to: alistURL)
    }

    try #require(fm.fileExists(atPath: csvURL.path),
                 "howell.csv fixture missing at \(csvURL.path)")
    // Either an alist.R or a *.ulam.swift driver is sufficient for the
    // pipeline to pick a path.
    try #require(fm.fileExists(atPath: alistURL.path)
                 || fm.fileExists(atPath: driverURL.path),
                 "howell driver missing — need howell.alist.R or Howell.ulam.swift")

    // Pre-stage `howell.init.json` so the alist path also gets inits.
    // `StanSample` auto-detects the file at sample time.
    try fm.createDirectory(at: paths.results,
                           withIntermediateDirectories: true)
    let initURL = paths.results.appendingPathComponent("howell.init.json")
    try #"{"mu":178.0,"sigma":25.0}"#
      .write(to: initURL, atomically: true, encoding: .utf8)

    let result = ulamPipeline(model: "howell", cmdstan: Self.cmdstan)
    try #require(result.1.isEmpty,
                 "ulamPipeline returned an error: \(result.1)")

    let stan = paths.results.appendingPathComponent("howell.stan")
    let data = paths.results.appendingPathComponent("howell.data.json")
    let summary = paths.results.appendingPathComponent("howell.stansummary.csv")
    #expect(fm.fileExists(atPath: stan.path))
    #expect(fm.fileExists(atPath: data.path))
    #expect(fm.fileExists(atPath: summary.path),
            "stansummary missing — sample step didn't complete")
    #expect(fm.fileExists(atPath: initURL.path),
            "init.json missing — was it written before sample ran?")

    // R-hat convergence. Threshold 1.05 is the standard
    // "good enough" bar; the howell2 hand-crafted-init demo proved
    // R-hat ≈ 1.001 for both parameters, so 1.05 is comfortable.
    let summaryText = try String(contentsOf: summary, encoding: .utf8)
    let muRhat = try #require(rhatFromSummary(summaryText, parameter: "mu"),
                              "mu R-hat row missing from summary")
    let sigmaRhat = try #require(rhatFromSummary(summaryText, parameter: "sigma"),
                                 "sigma R-hat row missing from summary")
    #expect(muRhat < 1.05,
            "mu R-hat = \(muRhat) (expected < 1.05) — sampler may have diverged")
    #expect(sigmaRhat < 1.05,
            "sigma R-hat = \(sigmaRhat) (expected < 1.05) — sampler may have diverged")
  }

  /// Pull the R-hat column out of cmdstan's clean stansummary CSV.
  /// Rows look like `"mu",149.5,…,1.001` — quoted name, comma-separated
  /// numbers, R-hat as the last column.
  private func rhatFromSummary(_ csv: String, parameter: String) -> Double? {
    for line in csv.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("\"\(parameter)\",") else { continue }
      let columns = trimmed.split(separator: ",")
      guard let last = columns.last,
            let value = Double(last) else { return nil }
      return value
    }
    return nil
  }
}
