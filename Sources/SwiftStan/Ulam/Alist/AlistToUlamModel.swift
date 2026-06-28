//
//  AlistToUlamModel.swift
//  Stan
//
//  Slice α of the `stancode` command (Docs/StancodeCommandPlan.md).
//  Twin of `AlistEmitter` — takes the same `ClassifiedAlist` input
//  but returns a runtime `UlamModel` value instead of formatting a
//  Swift smoke driver. The `stancode` command feeds the result
//  straight into `stancode(_: UlamModel) throws -> String`, skipping
//  the smoke-driver hop entirely.
//
//  Stub data values follow the same Q1(b) heuristic as `AlistEmitter`;
//  both paths consume `ClassifiedAlist.stubKind(for:)` so the two
//  paths can't drift.
//

import Foundation

internal enum AlistToUlamModel {
  internal static func build(_ classified: ClassifiedAlist) -> UlamModel {
    let data = buildData(classified)
    let statements = buildStatements(classified)
    return UlamModel(data: data, statements: statements)
  }

  // MARK: - Data

  private static func buildData(_ classified: ClassifiedAlist) -> UlamData {
    var out: UlamData = [:]
    var emitted: Set<String> = []
    if !classified.outcome.isEmpty, !emitted.contains(classified.outcome) {
      out[classified.outcome] = stubColumn(for: classified.outcome, in: classified)
      emitted.insert(classified.outcome)
    }
    // Bind synthesised vector-length cardinality symbols (v1: "J" → 2)
    // before generic data columns so vector/varying-vector priors
    // resolve their `length:` arguments.
    for (sym, len) in classified.lengthBindings where !emitted.contains(sym) {
      out[sym] = .scalarInt(len)
      emitted.insert(sym)
    }
    for col in classified.indexColumns where !emitted.contains(col) {
      out[col] = .integer([1])
      emitted.insert(col)
    }
    for col in classified.dataColumns where !emitted.contains(col) {
      out[col] = stubColumn(for: col, in: classified)
      emitted.insert(col)
    }
    return out
  }

  private static func stubColumn(for column: String,
                                 in classified: ClassifiedAlist) -> UlamColumn {
    switch classified.stubKind(for: column) {
    case .integer:
      return .integer([classified.indexColumns.contains(column) ? 1 : 0])
    case .real:
      return .real([0.0])
    }
  }

  // MARK: - Statements

  private static func buildStatements(_ classified: ClassifiedAlist) -> [Statement] {
    var out: [Statement] = []
    for stmt in classified.statements {
      switch stmt.kind {
      case .likelihood:
        out.append(.likelihood(lhs: stmt.name,
                               distribution: stmt.dist!,
                               truncation: stmt.truncation,
                               useLpdf: false))
      case .scalarPrior:
        out.append(.prior(name: stmt.name,
                          distribution: stmt.dist!,
                          truncation: stmt.truncation,
                          constraints: stmt.constraints,
                          start: nil,
                          useLpdf: false))
      case .varyingPrior(let idx):
        out.append(.varyingPrior(name: stmt.name,
                                 indexedBy: idx,
                                 countSymbol: nil,
                                 distribution: stmt.dist!,
                                 truncation: stmt.truncation,
                                 constraints: .none,
                                 start: nil,
                                 useLpdf: false,
                                 nonCentered: false))
      case .vectorPrior(let length):
        out.append(.vectorPrior(name: stmt.name,
                                length: length,
                                distribution: stmt.dist!,
                                truncation: stmt.truncation,
                                useLpdf: false))
      case .varyingVectorPrior(let idx, let length):
        out.append(.varyingVectorPrior(name: stmt.name,
                                       indexedBy: idx,
                                       length: length,
                                       countSymbol: nil,
                                       distribution: stmt.dist!,
                                       truncation: stmt.truncation,
                                       useLpdf: false))
      case .lkjCorrCholeskyPrior(let dim):
        // The dlkjcorr Distribution has its eta arg in slot 0.
        guard case .lkjCorrCholesky(let eta) = stmt.dist! else {
          fatalError("dlkjcorr classify produced a non-lkjCorrCholesky distribution")
        }
        out.append(.lkjCorrCholeskyPrior(name: stmt.name, dim: dim, eta: eta))
      case .link(let fn):
        let source = AlistEmitter.canonicalExpression(stmt.linkRhs!)
        out.append(.link(function: fn,
                         lhs: stmt.name,
                         rhs: Expression(source)))
      case .deterministic:
        // Bare `<name> <- <rhs>` from the alist front-end. Routed
        // through `Statement.deterministic` so the BlockEmitter writes
        // a plain `<name> = <rhs>;` line in the model block (no
        // inv_logit / exp wrapper).
        let source = AlistEmitter.canonicalExpression(stmt.linkRhs!)
        out.append(.deterministic(lhs: stmt.name,
                                  rhs: Expression(source)))
      case .generatedQuantity:
        out.append(.generatedQuantity(name: stmt.name,
                                      distribution: stmt.dist!))
      }
    }
    return out
  }
}
