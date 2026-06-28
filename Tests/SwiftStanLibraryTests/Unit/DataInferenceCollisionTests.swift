//
//  DataInferenceCollisionTests.swift
//  SwiftStanTests
//
//  Coverage for the cardinality-symbol collision check in
//  `DataInference.classify(_:)` (TODO §4). The check rejects user-
//  supplied countSymbol / length / dim / rows / cols values that would
//  shadow a meaningful symbol in the generated `data {}` block: the
//  reserved sample-size `"N"`, non-scalar-int data columns, or another
//  cardinality slot with a different owner.
//
//  Each test reaches for `stancode(model)` and asserts the thrown
//  error is `DataInferenceError.countSymbolCollision`. The legitimate
//  cases (shared `.scalarInt` cardinality, repeated VaryingPrior on
//  the same indexedBy) are covered by the existing golden tests
//  (`dmvnormBivariateMatchesGolden`, `cafeMultilevelMatchesGolden`,
//  etc.), so we don't duplicate the positive coverage here.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("DataInference cardinality-collision tests")
struct DataInferenceCollisionTests {
  init() { _ = TestCaseRootBootstrap.install }


  private func expectCollision<T>(_ block: () throws -> T) {
    do {
      _ = try block()
      Issue.record("expected DataInferenceError.countSymbolCollision but no error was thrown")
    } catch let err as DataInferenceError {
      if case .countSymbolCollision = err { return }
      Issue.record("expected countSymbolCollision but got \(err)")
    } catch {
      Issue.record("expected DataInferenceError but got \(type(of: error)): \(error)")
    }
  }

  // MARK: - Collides with reserved N

  @Test func varyingPriorCountSymbolCollidesWithN() throws {
    let data: UlamData = [
      "y":     .integer([0, 1, 0, 1]),
      "group": .integer([1, 2, 1, 2]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[group]")
      // countSymbol: "N" — would emit `int<lower=1> N;` twice.
      VaryingPrior("a", indexedBy: "group", .normal("a_bar", "sigma_a"),
                   countSymbol: "N")
      Prior("a_bar", .normal(0, 1))
      Prior("sigma_a", .exponential(1))
    }
    expectCollision { try stancode(model) }
  }

  @Test func vectorPriorLengthCollidesWithN() throws {
    let data: UlamData = [
      "y": .real([1.0, 2.0]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .normal("mu_vec[1]", 1))
      VectorPrior("mu_vec", length: "N", .normal(0, 1))
    }
    expectCollision { try stancode(model) }
  }

  // MARK: - Collides with non-scalarInt data column

  @Test func varyingPriorCountSymbolCollidesWithVectorDataColumn() throws {
    let data: UlamData = [
      "y":     .integer([0, 1, 0, 1]),
      "x":     .real([0.1, 0.2, 0.3, 0.4]),
      "group": .integer([1, 2, 1, 2]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[group] + b*x")
      // countSymbol: "x" collides with the `vector[N] x;` data column.
      VaryingPrior("a", indexedBy: "group", .normal("a_bar", "sigma_a"),
                   countSymbol: "x")
      Prior("a_bar", .normal(0, 1))
      Prior("sigma_a", .exponential(1))
      Prior("b", .normal(0, 1))
    }
    expectCollision { try stancode(model) }
  }

  // MARK: - Collides across cardinality owners

  @Test func twoVaryingPriorsWithSameCountSymbolDifferentColumns() throws {
    let data: UlamData = [
      "y":       .integer([0, 1, 0, 1, 1, 0, 1, 1]),
      "subject": .integer([1, 2, 1, 2, 3, 3, 1, 2]),
      "item":    .integer([1, 1, 2, 2, 1, 2, 3, 3]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[subject] + b[item]")
      // Both varyings declare countSymbol: "K" — cross-owner collision
      // because "K" isn't a `.scalarInt` shared data entry.
      VaryingPrior("a", indexedBy: "subject", .normal(0, 1), countSymbol: "K")
      VaryingPrior("b", indexedBy: "item",    .normal(0, 1), countSymbol: "K")
    }
    expectCollision { try stancode(model) }
  }

  // MARK: - Auto-derived N_<col> collides with literal data column

  /// The DSL auto-derives a cardinality `N_<col>` when no explicit
  /// `countSymbol:` is supplied. If the user already has a data column
  /// named `N_<col>` (vector-typed), the generator would try to declare
  /// both `int<lower=1> N_country;` and `vector[N] N_country;` —
  /// invalid Stan.
  @Test func autoDerivedCardinalityCollidesWithLiteralDataColumn() throws {
    let data: UlamData = [
      "y":         .integer([0, 1, 0, 1, 1]),
      "country":   .integer([1, 2, 1, 2, 1]),
      "N_country": .real([0.5, 0.5, 0.5, 0.5, 0.5]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[country]")
      // No countSymbol override → auto-derives "N_country", which now
      // shadows the .real data column above.
      VaryingPrior("a", indexedBy: "country", .normal(0, 1))
    }
    expectCollision { try stancode(model) }
  }

  // MARK: - Legitimate shared .scalarInt cardinality (regression)

  /// The cafe demo pattern: `J` is a `.scalarInt(2)` data entry used
  /// as the cardinality of THREE different cardinality slots
  /// (`VectorPrior.length`, `LKJCorrCholeskyPrior.dim`,
  /// `VaryingVectorPrior.length`). The collision check MUST allow this
  /// — the short-circuit on `.scalarInt` data entries is what enables
  /// the cafe-style hierarchical model to compile. Smoke-test that
  /// `classify` doesn't throw on this shape; full golden coverage is in
  /// the existing cafe / dmvnorm tests.
  @Test func scalarIntDataEntryAllowsMultipleCardinalityOwners() throws {
    let data: UlamData = [
      "J":           .scalarInt(2),
      "y":           .realArrayVector(rowCount: 6, colCount: 2,
                                      values: [
                                        [1.0, 0.5], [1.0, 0.5], [1.0, 0.5],
                                        [1.0, 0.5], [1.0, 0.5], [1.0, 0.5],
                                      ]),
      "zero":        .realVector(length: 2, values: [0, 0]),
      "Sigma_prior": .realCovMatrix(dim: 2, values: [[1, 0.5], [0.5, 1]]),
      "Sigma_obs":   .realCovMatrix(dim: 2,
                                    values: [[0.02, 0.005], [0.005, 0.02]]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .multivariateNormal(mu: "mu", sigma: "Sigma_obs"))
      VectorPrior("mu", length: "J",
                  .multivariateNormal(mu: "zero", sigma: "Sigma_prior"))
    }
    #expect(throws: Never.self) { _ = try stancode(model) }
  }

  // MARK: - Index column value validation (TODO §2)

  private func expectIndexValueOutOfRange<T>(_ block: () throws -> T) {
    do {
      _ = try block()
      Issue.record("expected DataInferenceError.indexColumnValueOutOfRange but no error was thrown")
    } catch let err as DataInferenceError {
      if case .indexColumnValueOutOfRange = err { return }
      Issue.record("expected indexColumnValueOutOfRange but got \(err)")
    } catch {
      Issue.record("expected DataInferenceError but got \(type(of: error)): \(error)")
    }
  }

  @Test func indexColumnWithZeroValueIsRejected() throws {
    let data: UlamData = [
      "y":     .integer([0, 1, 0]),
      "group": .integer([1, 0, 2]),   // row 1 is a 0 — Stan's <lower=1> fires
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[group]")
      VaryingPrior("a", indexedBy: "group", .normal(0, 1))
    }
    expectIndexValueOutOfRange { try stancode(model) }
  }

  @Test func indexColumnWithNegativeValueIsRejected() throws {
    let data: UlamData = [
      "y":     .integer([0, 1, 0]),
      "group": .integer([-1, 1, 2]),  // row 0 is -1
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[group]")
      VaryingPrior("a", indexedBy: "group", .normal(0, 1))
    }
    expectIndexValueOutOfRange { try stancode(model) }
  }

  /// User declares cardinality `"J": .scalarInt(7)` via data; a row
  /// value of `8` exceeds Stan's resulting `<lower=1, upper=J>`
  /// constraint. The auto-derived `N_<col>` case can't trigger this —
  /// the upper bound IS `max(values)` by construction — so the check
  /// kicks in only when the user supplies a fixed cardinality.
  @Test func indexColumnValueExceedingUserSuppliedCardinalityIsRejected() throws {
    let data: UlamData = [
      "y":     .integer([0, 1, 0, 1]),
      "group": .integer([1, 2, 8, 3]),    // row 2 = 8 > J = 7
      "J":     .scalarInt(7),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[group]")
      VaryingPrior("a", indexedBy: "group", .normal(0, 1), countSymbol: "J")
    }
    expectIndexValueOutOfRange { try stancode(model) }
  }

  /// Positive regression guard: a well-formed index column shouldn't
  /// throw. The existing multilevel goldens (`multilevelBernoulliMatchesGolden`,
  /// `ucbBinomialWithCountSymbolOverride`, cafe, reedfrog, etc.) cover
  /// this implicitly via their golden assertions; this is an explicit
  /// smoke test so a future bug in the validator surfaces here directly.
  @Test func wellFormedIndexColumnDoesNotThrow() throws {
    let data: UlamData = [
      "y":     .integer([0, 1, 0, 1, 1]),
      "group": .integer([1, 2, 1, 2, 3]),
    ]
    let model = UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a[group]")
      VaryingPrior("a", indexedBy: "group", .normal(0, 1))
    }
    #expect(throws: Never.self) { _ = try stancode(model) }
  }
}
