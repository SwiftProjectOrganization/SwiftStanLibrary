//
//  UlamModel.swift
//  Stan
//
//  Phase 1 of the ulam port: the top-level model value.
//
//      let m = UlamModel(data: d) {
//        Likelihood("y", .bernoulli(p: "p"))
//        Link(.logit, lhs: "p", rhs: "a + b*x")
//        Prior("a", .normal(0, 1.5))
//        Prior("b", .normal(0, 0.5))
//      }
//
//  Phase 1 only holds the AST + data. Phase 2 adds orchestration that
//  writes <name>.stan / <name>.data.json and invokes compile / sample.
//

import Foundation

public struct UlamModel: Sendable {
  public let statements: [Statement]
  public let data: UlamData

  public init(data: UlamData,
              @StanModelBuilder _ build: () -> [Statement]) {
    self.data = data
    self.statements = build()
  }

  /// Direct init used by code paths that have already computed the
  /// statement list (e.g. the `stancode` command's
  /// `AlistToUlamModel` converter). Bypasses the result-builder.
  public init(data: UlamData, statements: [Statement]) {
    self.data = data
    self.statements = statements
  }
}
