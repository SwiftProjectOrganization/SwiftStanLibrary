//
//  Generated_QuantitiesEmitTests.swift
//  StanTests
//
//  Verifies that `y_tilde <- sim(dnorm(...))` (and the discrete analogue)
//  is parsed, lowered, classified, and emitted as a `generated quantities`
//  block by the stancode pipeline. Also checks the fail-loud guard that
//  rejects a sim() whose distribution references a model-block local.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("Generated quantities emission tests")
struct Generated_QuantitiesEmitTests {
  init() { _ = TestCaseRootBootstrap.install }

  // MARK: - Fixtures

  static let continuousAlist = """
    alist(
      log_radon ~ dnorm(alpha + beta*floor, sigma),
      alpha ~ dnorm(0, 10),
      beta ~ dnorm(0, 10),
      sigma ~ dnorm(0, 10),
      y_tilde <- sim(dnorm(alpha + beta*floor, sigma))
    )
    """

  // `p` is a parameter (dbeta prior), not a link target, so it IS
  // accessible in the generated quantities block.
  static let discreteAlist = """
    alist(
      y ~ dbern(p),
      p ~ dbeta(2, 2),
      y_tilde <- sim(dbern(p))
    )
    """

  // When `p` is behind a link, the user must inline the inverse-link
  // expression in sim() — p is a model-block local and not in scope
  // for generated quantities.
  static let logitLinkAlist = """
    alist(
      y ~ dbinom(1, p),
      logit(p) <- a + b*x,
      a ~ dnorm(0, 1.5),
      b ~ dnorm(0, 0.5),
      y_tilde <- sim(dbinom(1, inv_logit(a + b*x)))
    )
    """

  // MARK: - Parser recognises sim(...)

  @Test func parserProducesGeneratedQuantityStatement() throws {
    let stmts = try AlistParser.parse(Self.continuousAlist)
    // Last statement should be a generatedQuantity
    guard case let .generatedQuantity(target, dist) = stmts.last else {
      Issue.record("expected .generatedQuantity, got \(String(describing: stmts.last))")
      return
    }
    #expect(target == "y_tilde")
    #expect(dist.name == "dnorm")
  }

  @Test func parserBareAssignNotConfusedWithSim() throws {
    // A plain deterministic line must NOT become a generatedQuantity
    let src = """
      alist(
        y ~ dnorm(mu, sigma),
        mu ~ dnorm(0, 10),
        sigma ~ dnorm(0, 1),
        derived <- mu + 1
      )
      """
    let stmts = try AlistParser.parse(src)
    guard case let .link(fn, _, _) = stmts.last else {
      Issue.record("expected .link, got \(String(describing: stmts.last))")
      return
    }
    #expect(fn == .identity)
  }

  // MARK: - Golden Stan output (continuous)

  @Test func continuousAlistEmitsNormalRngBlock() throws {
    let stmts = try AlistParser.parse(Self.continuousAlist)
    let lowered = try AlistLowering.lower(stmts)
    let classified = try AlistClassify.classify(lowered)
    let model = AlistToUlamModel.build(classified)
    let stan = try stancode(model)

    #expect(stan.contains("generated quantities {"))
    #expect(stan.contains("array[N] real y_tilde = normal_rng(alpha + beta*floor, sigma);"))
    #expect(stan.contains("}"))
    // GQ block must come after the model block
    let modelRange = stan.range(of: "model {")
    let gqRange   = stan.range(of: "generated quantities {")
    if let m = modelRange, let g = gqRange {
      #expect(m.lowerBound < g.lowerBound, "generated quantities must follow model block")
    } else {
      Issue.record("missing model or generated quantities block")
    }
  }

  // MARK: - Golden Stan output (discrete — bernoulli_rng)

  @Test func discreteAlistEmitsBernoulliRngBlock() throws {
    let stmts = try AlistParser.parse(Self.discreteAlist)
    let lowered = try AlistLowering.lower(stmts)
    let classified = try AlistClassify.classify(lowered)
    let model = AlistToUlamModel.build(classified)
    let stan = try stancode(model)

    #expect(stan.contains("generated quantities {"))
    // dbern(p) → bernoulli_rng(p); discrete → array[N] int
    #expect(stan.contains("array[N] int y_tilde = bernoulli_rng(p);"))
  }

  // MARK: - Logit-link model: user inlines inv_logit in sim()

  @Test func logitLinkAlistWithInlinedInvLogit() throws {
    let stmts = try AlistParser.parse(Self.logitLinkAlist)
    let lowered = try AlistLowering.lower(stmts)
    let classified = try AlistClassify.classify(lowered)
    let model = AlistToUlamModel.build(classified)
    let stan = try stancode(model)

    #expect(stan.contains("generated quantities {"))
    // dbinom(1, inv_logit(…)) collapses to bernoulli → bernoulli_rng
    #expect(stan.contains("array[N] int y_tilde = bernoulli_rng(inv_logit(a + b*x));"))
  }

  // MARK: - y_tilde excluded from data columns

  @Test func generatedQuantityNameNotInDataColumns() throws {
    let stmts = try AlistParser.parse(Self.continuousAlist)
    let lowered = try AlistLowering.lower(stmts)
    let classified = try AlistClassify.classify(lowered)
    #expect(!classified.dataColumns.contains("y_tilde"))
  }

  // MARK: - Models without sim() are byte-identical (no GQ block)

  @Test func modelWithoutSimHasNoGQBlock() throws {
    let src = """
      alist(
        log_radon ~ dnorm(alpha + beta*floor, sigma),
        alpha ~ dnorm(0, 10),
        beta ~ dnorm(0, 10),
        sigma ~ dnorm(0, 10)
      )
      """
    let stmts = try AlistParser.parse(src)
    let lowered = try AlistLowering.lower(stmts)
    let classified = try AlistClassify.classify(lowered)
    let model = AlistToUlamModel.build(classified)
    let stan = try stancode(model)
    #expect(!stan.contains("generated quantities"))
  }

  // MARK: - Swift DSL `Sim` node

  @Test func simDSLNodeEmitsGenerated_QuantitiesBlock() throws {
    let data: UlamData = [
      "log_radon": .real([1.0, 2.0, 3.0]),
      "floor":     .real([0.0, 1.0, 0.0]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("log_radon", .normal(.expression("alpha + beta*floor"), "sigma"))
      Prior("alpha", .normal(0, 10))
      Prior("beta",  .normal(0, 10))
      Prior("sigma", .normal(0, 1), truncation: Truncation(lower: 0))
      Sim("y_rep", .normal(.expression("alpha + beta*floor"), "sigma"))
    }
    let stan = try stancode(model)
    #expect(stan.contains("generated quantities {"))
    #expect(stan.contains("array[N] real y_rep = normal_rng(alpha + beta*floor, sigma);"))
  }

  // MARK: - Fail-loud: unsupported sim() distributions

  @Test func simWithMultivariateDistributionThrows() throws {
    // `multi_normal_rng` returns a vector — not a scalar — so the
    // `array[N] real` declaration would be wrong Stan. Guard fires at
    // DataInference time, before any Stan is emitted.
    let data: UlamData = ["y": .real([1.0, 2.0, 3.0]),
                          "x": .real([0.1, 0.2, 0.3])]
    let model = UlamModel(data: data) {
      Likelihood("y", .normal("mu", "sigma"))
      Prior("mu", .normal(0, 1))
      Prior("sigma", .normal(0, 1), truncation: Truncation(lower: 0))
      Sim("y_rep", .multivariateNormal(mu: "mu", sigma: "sigma"))
    }
    #expect(throws: DataInferenceError.self) {
      _ = try stancode(model)
    }
  }

  @Test func simWithLkjThrows() throws {
    // `lkj_corr_cholesky_rng` does not exist in Stan's function library.
    let data: UlamData = ["y": .real([1.0, 2.0, 3.0])]
    let model = UlamModel(data: data) {
      Likelihood("y", .normal(0, 1))
      Sim("L_rep", .lkjCorrCholesky(2))
    }
    #expect(throws: DataInferenceError.self) {
      _ = try stancode(model)
    }
  }

  // MARK: - Fail-loud: sim() referencing a model-block local

  @Test func simReferencingLocalThrows() throws {
    // `mu` is a model-block local (deterministic assignment).
    // A sim() referencing it must throw.
    let src = """
      alist(
        y ~ dnorm(mu, sigma),
        mu <- alpha + beta*x,
        alpha ~ dnorm(0, 10),
        beta ~ dnorm(0, 1),
        sigma ~ dnorm(0, 1),
        y_tilde <- sim(dnorm(mu, sigma))
      )
      """
    let stmts = try AlistParser.parse(src)
    let lowered = try AlistLowering.lower(stmts)
    let classified = try AlistClassify.classify(lowered)
    let model = AlistToUlamModel.build(classified)
    #expect(throws: (any Error).self) {
      _ = try stancode(model)
    }
  }
}
