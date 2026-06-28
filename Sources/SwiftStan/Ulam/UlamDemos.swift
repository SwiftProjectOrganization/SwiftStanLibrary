// UlamDemos.swift
// Factory methods for the canonical test/demo UlamModels.
// Kept in the library so tests can call SwiftStan.Ulam.bernoulliDemo() etc.
// via @testable import SwiftStan without depending on the CLI target.

import Foundation

enum Ulam {

  static func bernoulliDemo() -> UlamModel {
    let data: UlamData = [
      "y": .integer([0, 1, 0, 1, 1, 0, 1, 1, 1, 0]),
      "x": .real([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]),
    ]
    return UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a + b*x")
      Prior("a", .normal(0, 1.5))
      Prior("b", .normal(0, 0.5))
    }
  }

  static func poissonDemo() -> UlamModel {
    let data: UlamData = [
      "y": .integer([2, 1, 3, 5, 4, 6, 8, 7]),
      "x": .real([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
    ]
    return UlamModel(data: data) {
      Likelihood("y", .poisson("lambda"), useLpdf: true)
      Link(.log, lhs: "lambda", rhs: "a + b*x")
      Prior("a", .normal(0, 1.5))
      Prior("b", .cauchy(0, 1))
    }
  }

  static func ucbDemo() -> UlamModel {
    let data: UlamData = [
      "admit":        .integer([512, 89, 353, 17, 120, 202, 138, 131, 53, 94, 22, 24]),
      "applications": .integer([825, 108, 560, 25, 325, 593, 417, 375, 191, 393, 373, 341]),
      "male":         .integer([1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0]),
      "dept":         .integer([1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6]),
    ]
    return UlamModel(data: data) {
      Likelihood("admit", .binomial(n: "applications", p: "p"))
      Link(.logit, lhs: "p", rhs: "a[dept] + b*male")
      VaryingPrior("a", indexedBy: "dept",
                   .normal("abar", "sigma"))
      Prior("abar", .normal(0, 4))
      Prior("sigma", .normal(0, 1), truncation: Truncation(lower: 0))
      Prior("b", .normal(0, 1))
    }
  }

  static func dmvnormDemo() -> UlamModel {
    let observations: [[Double]] = [
      [1.10, 0.42], [0.92, 0.61], [1.05, 0.48], [1.21, 0.34],
      [0.88, 0.55], [1.14, 0.39], [1.02, 0.52], [0.95, 0.58],
      [1.18, 0.36], [1.08, 0.47], [0.97, 0.56], [1.03, 0.50],
      [1.12, 0.41], [0.99, 0.54], [1.16, 0.37], [0.91, 0.60],
      [1.07, 0.46], [1.04, 0.49], [0.96, 0.57], [1.10, 0.43],
    ]
    let data: UlamData = [
      "y":           .realArrayVector(rowCount: observations.count,
                                      colCount: 2,
                                      values: observations),
      "zero":        .realVector(length: 2, values: [0, 0]),
      "Sigma_prior": .realCovMatrix(dim: 2, values: [[1, 0.5], [0.5, 1]]),
      "Sigma_obs":   .realCovMatrix(dim: 2,
                                    values: [[0.02, 0.005], [0.005, 0.02]]),
    ]
    return UlamModel(data: data) {
      Likelihood("y", .multivariateNormal(mu: "mu", sigma: "Sigma_obs"))
      VectorPrior("mu", length: "K",
                  .multivariateNormal(mu: "zero", sigma: "Sigma_prior"))
    }
  }

  static func binomialDemo() -> UlamModel {
    let data: UlamData = [
      "successes": .integer([2, 3, 1, 4, 5, 6, 7, 8]),
      "trials":    .integer([5, 5, 5, 5, 10, 10, 10, 10]),
      "x":         .real([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]),
    ]
    return UlamModel(data: data) {
      Likelihood("successes", .binomial(n: "trials", p: "theta"))
      Link(.logit, lhs: "theta", rhs: "a + b*x")
      Prior("a", .normal(0, 1.5))
      Prior("b", .normal(0, 1), truncation: Truncation(lower: 0))
    }
  }

  static func varyingSlopesDemo() -> UlamModel {
    let data: UlamData = [
      "y":     .integer([0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0]),
      "x":     .real([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.2, 0.5, 0.7, 0.3]),
      "group": .integer([1, 2, 1, 2, 1, 2, 1, 2, 1, 2, 1, 2]),
    ]
    return UlamModel(data: data) {
      Likelihood("y", .bernoulli(p: "p"))
      Link(.logit, lhs: "p", rhs: "a + b[group]*x")
      Prior("a", .normal(0, 1.5))
      VaryingPrior("b", indexedBy: "group", .normal("b_bar", "sigma_b"))
      Prior("b_bar", .normal(0, 1))
      Prior("sigma_b", .exponential(1))
    }
  }

  static func cafeDemo() -> UlamModel {
    let cafe: [Int] = (1...6).flatMap { Array(repeating: $0, count: 10) }
    let afternoon: [Int] = Array(repeating: [0,0,0,0,0,1,1,1,1,1],
                                 count: 6).flatMap { $0 }
    let wait: [Double] = [
      3.81, 4.22, 3.95, 4.14, 4.08, 2.46, 2.74, 2.61, 2.39, 2.55,
      3.04, 3.34, 3.18, 3.27, 3.11, 2.31, 2.52, 2.40, 2.48, 2.36,
      3.58, 3.81, 3.62, 3.74, 3.69, 2.40, 2.62, 2.54, 2.45, 2.58,
      2.81, 2.94, 2.86, 3.01, 2.92, 2.32, 2.50, 2.41, 2.38, 2.45,
      4.04, 4.31, 4.12, 4.24, 4.18, 2.42, 2.65, 2.51, 2.58, 2.46,
      3.27, 3.50, 3.38, 3.46, 3.41, 2.44, 2.62, 2.55, 2.49, 2.58,
    ]
    let data: UlamData = [
      "J":         .scalarInt(2),
      "cafe":      .integer(cafe),
      "afternoon": .integer(afternoon),
      "wait":      .real(wait),
    ]
    return UlamModel(data: data) {
      Likelihood("wait", .normal("mu", "sigma"))
      Deterministic("mu", "ab[cafe][1] + ab[cafe][2] * afternoon")
      Prior("a_bar", .normal(0, 5))
      Prior("b_bar", .normal(0, 5))
      Prior("sigma", .exponential(1), truncation: Truncation(lower: 0))
      VectorPrior("sigma_ab", length: "J", .exponential(1),
                  truncation: Truncation(lower: 0))
      LKJCorrCholeskyPrior("L_Omega", dim: "J", eta: 2)
      VaryingVectorPrior("ab", indexedBy: "cafe", length: "J",
                         .multivariateNormalCholesky(
                           mean: "[a_bar, b_bar]'",
                           chol: "diag_pre_multiply(sigma_ab, L_Omega)"))
    }
  }

  static func reedfrogDemo() -> UlamModel {
    let data: UlamData = [
      "y":       .integer([3, 5, 4, 2, 7, 8, 6, 7, 4, 5, 3, 6, 8, 9, 7, 8]),
      "density": .integer([10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10]),
      "tank":    .integer([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]),
      "size":    .integer([1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2]),
    ]
    return UlamModel(data: data) {
      Likelihood("y", .binomial(n: "density", p: "p"))
      Link(.logit, lhs: "p", rhs: "a[tank] + s[size]")
      VaryingPrior("a", indexedBy: "tank", .normal("a_bar", "sigma_a"))
      VaryingPrior("s", indexedBy: "size", .normal(0, "sigma_s"))
      Prior("a_bar", .normal(0, 1.5))
      Prior("sigma_a", .normal(0, 1), truncation: Truncation(lower: 0))
      Prior("sigma_s", .normal(0, 1), truncation: Truncation(lower: 0))
    }
  }
}
