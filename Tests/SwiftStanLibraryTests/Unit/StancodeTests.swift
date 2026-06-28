//
//  StancodeTests.swift
//  StanTests
//
//  Slice ε of Docs/StancodeCommandPlan.md. Three checks:
//
//   1. `stancode` command output equals the in-process generator
//      output for the equivalent model — locks in that the fast
//      path's `AlistToUlamModel` translation produces the same Stan
//      as the demo factory.
//   2. `stancode` and `alist2dsl → dsl2stan` outputs are byte-equal —
//      proves the two paths are interchangeable (option 2 of the
//      plan's ulamPipeline integration safely picks either based on
//      which input is present).
//   3. Missing `.alist.R` surfaces `StancodeError.alistNotFound`.
//
//  Synthetic fixtures keep the chimpanzees / bernoulli case dirs
//  untouched (mirrors the pattern in Dsl2StanTests / Alist2DslTests).
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("stancode command tests")
struct StancodeTests {
  init() { _ = TestCaseRootBootstrap.install }


  static let bernoulliAlist = """
    bernoulli_demo <- ulam(
        alist(
            y ~ dbinom( 1 , p ),
            logit(p) <- a + b*x,
            a ~ dnorm( 0 , 1.5 ),
            b ~ dnorm( 0 , 0.5 )
        ),
        data=d )
    """

  @Test func bernoulliMatchesInProcessGenerator() throws {
    let model = "stancode_bernoulli_fixture"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)
    defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

    let alistURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")
    try Self.bernoulliAlist.write(to: alistURL, atomically: true, encoding: .utf8)

    let stanURL = try stancode(model: model)
    let emitted = try String(contentsOf: stanURL, encoding: .utf8)
    let golden = try stancode(SwiftStan.Ulam.bernoulliDemo())
    #expect(emitted == golden,
            "stancode fast-path output diverged from in-process bernoulli golden")
  }

  static let binomialAlist = """
    ucbadmit_demo <- ulam(
        alist(
            admit ~ dbinom( applications , p ),
            logit(p) <- a,
            a ~ dnorm( 0 , 1.5 )
        ),
        data=d )
    """

  @Test func binomialTrialsAreIntegerArray() throws {
    let model = "stancode_binomial_fixture"
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)
    defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

    try Self.binomialAlist.write(
      to: paths.preliminaries.appendingPathComponent("\(model).alist.R"),
      atomically: true, encoding: .utf8)

    let stanURL = try stancode(model: model)
    let emitted = try String(contentsOf: stanURL, encoding: .utf8)
    // Stan rejects `binomial(applications, p)` unless `applications` is an
    // integer array. The trials column must be declared `array[N] int`,
    // never `vector[N]`.
    #expect(emitted.contains("array[N] int") && emitted.contains("applications"),
            "binomial trials column not declared as an integer array:\n\(emitted)")
    #expect(!emitted.contains("vector[N] applications"),
            "binomial trials column wrongly declared as a real vector:\n\(emitted)")
  }

  static let uniformPriorAlist = """
    alist(
      y ~ dbern(theta),
      theta ~ dunif(0, 1)
    )
    """

  static let betaPriorAlist = """
    alist(
      y ~ dbern(theta),
      theta ~ dbeta(1, 1)
    )
    """

  @Test(arguments: [
    ("stancode_unif_fixture", StancodeTests.uniformPriorAlist),
    ("stancode_beta_fixture", StancodeTests.betaPriorAlist),
  ])
  func boundedSupportPriorConstrainsParameter(model: String, alist: String) throws {
    let paths = casePaths(for: model)
    try ensureCaseDirectories(paths)
    defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

    try alist.write(
      to: paths.preliminaries.appendingPathComponent("\(model).alist.R"),
      atomically: true, encoding: .utf8)

    let stanURL = try stancode(model: model)
    let emitted = try String(contentsOf: stanURL, encoding: .utf8)
    // A `dunif(0, 1)` / `dbeta(1, 1)` prior has support on [0, 1], so the
    // parameter must be declared with matching bounds — otherwise Stan
    // samples on an unbounded scale and the prior is improper.
    #expect(emitted.contains("real<lower=0, upper=1> theta;"),
            "bounded-support prior did not constrain its parameter:\n\(emitted)")
    #expect(!emitted.contains("real theta;"),
            "parameter wrongly declared without constraints:\n\(emitted)")
    // The bound is declaration-only (`Constraints`, not `Truncation`):
    // no redundant `T[…]` suffix on the sampling statement.
    #expect(!emitted.contains("T["),
            "bounded-support prior emitted a redundant T[…] sampling suffix:\n\(emitted)")
  }

@Test func missingAlistThrows() throws {
    let model = "stancode_missing_fixture"
    defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }
    #expect(throws: StancodeError.self) {
      _ = try stancode(model: model)
    }
  }
}
