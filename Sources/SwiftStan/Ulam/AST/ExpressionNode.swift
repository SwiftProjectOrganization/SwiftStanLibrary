//
//  ExpressionNode.swift
//  Stan
//
//  Phase 5.5 Slice A: parsed form of `Expression.source`. Internal —
//  the public `Expression` API keeps its raw-string shape; this node
//  is only consulted by the generator. Pairs with the lexer + parser
//  under `Generator/`.
//

import Foundation

internal indirect enum ExpressionNode: Hashable, Sendable {
  case identifier(String)
  case literal(Literal)
  case indexed(name: String, index: ExpressionNode)
  case binary(op: BinaryOp, lhs: ExpressionNode, rhs: ExpressionNode)
  case unary(op: UnaryOp, operand: ExpressionNode)
  /// Single-argument function call (e.g. `inv_logit(a + b*x)`). v1.5
  /// only needs the unary form for link wrappers; multi-arg falls out
  /// of scope (deferred to v2).
  case call(name: String, argument: ExpressionNode)
  /// Multivariate hierarchical priors Slice D (2026-05-31): chained
  /// element access `name[outer][inner]` for vector-of-vectors lookups
  /// against a `VaryingVectorPrior`-typed parameter — typically
  /// `ab[cafe][1]` where `ab` is `array[N_cafe] vector[J]`. v1 supports
  /// exactly this two-level shape; deeper nesting is rejected.
  case chainedIndexed(name: String,
                      outerIndex: ExpressionNode,
                      innerIndex: ExpressionNode)
  /// Nested-groupings 2-arg matrix indexing (2026-06-03): `a[i, j]`
  /// against a `matrix[K, J]`-typed parameter (typically a
  /// `NestedVaryingPrior` over (country, region) etc.). v1 supports
  /// the 2-arg case only; 3+ comma-separated indices are rejected by
  /// the parser. Distinct from `.chainedIndexed` — Stan rejects
  /// `a[i][j]` chained form on matrix parameters; the comma form is
  /// the only valid shape.
  case subscript2(name: String,
                  idx1: ExpressionNode,
                  idx2: ExpressionNode)
}

internal enum Literal: Hashable, Sendable {
  case integer(Int)
  case float(Double)
}

internal enum BinaryOp: String, Hashable, Sendable {
  case add = "+"
  case subtract = "-"
  case multiply = "*"
  case divide = "/"
}

internal enum UnaryOp: String, Hashable, Sendable {
  case negate = "-"
}

/// One reference to a named symbol inside a parsed expression. The
/// walker emits one `SymbolUse` per distinct (name, indexed-shape)
/// combination — so `a + a[i]` produces two entries (one with
/// `isIndexed: false`, one with `isIndexed: true`).
internal struct SymbolUse: Hashable, Sendable {
  internal let name: String
  /// True when this reference appears as `name[...]`.
  internal let isIndexed: Bool
  /// True when this reference appears inside some other `[...]`.
  internal let isInsideIndex: Bool
}

extension ExpressionNode {
  /// Walks the tree and returns every named symbol it references.
  /// Function-call callee names (e.g. `inv_logit` in `inv_logit(a)`)
  /// are NOT treated as symbol references — they're function names.
  internal func symbolReferences() -> Set<SymbolUse> {
    var uses: Set<SymbolUse> = []
    collect(into: &uses, insideIndex: false)
    return uses
  }

  private func collect(into uses: inout Set<SymbolUse>, insideIndex: Bool) {
    switch self {
    case .identifier(let name):
      uses.insert(SymbolUse(name: name,
                            isIndexed: false,
                            isInsideIndex: insideIndex))
    case .literal:
      break
    case .indexed(let name, let index):
      uses.insert(SymbolUse(name: name,
                            isIndexed: true,
                            isInsideIndex: insideIndex))
      index.collect(into: &uses, insideIndex: true)
    case .binary(_, let lhs, let rhs):
      lhs.collect(into: &uses, insideIndex: insideIndex)
      rhs.collect(into: &uses, insideIndex: insideIndex)
    case .unary(_, let operand):
      operand.collect(into: &uses, insideIndex: insideIndex)
    case .call(_, let argument):
      argument.collect(into: &uses, insideIndex: insideIndex)
    case .chainedIndexed(let name, let outerIndex, let innerIndex):
      // The outer name is the indexed-into varying-vector parameter;
      // the outer index is itself a data column (typically the group
      // id), the inner index is the per-vector slot.
      uses.insert(SymbolUse(name: name,
                            isIndexed: true,
                            isInsideIndex: insideIndex))
      outerIndex.collect(into: &uses, insideIndex: true)
      innerIndex.collect(into: &uses, insideIndex: true)
    case .subscript2(let name, let idx1, let idx2):
      // Nested-groupings: `a[i, j]` over a matrix parameter. Both
      // indices are typically data columns (e.g. country / region).
      uses.insert(SymbolUse(name: name,
                            isIndexed: true,
                            isInsideIndex: insideIndex))
      idx1.collect(into: &uses, insideIndex: true)
      idx2.collect(into: &uses, insideIndex: true)
    }
  }
}
