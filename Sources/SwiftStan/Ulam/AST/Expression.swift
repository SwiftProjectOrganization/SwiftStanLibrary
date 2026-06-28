//
//  Expression.swift
//  Stan
//
//  Phase 1 of the ulam port: a thin wrapper around a raw expression
//  string. The public API keeps its v1 shape — expressions are
//  emitted verbatim into Stan source.
//
//  Phase 5.5 Slice A added an internal parser-backed view of the
//  same source (`parsed()` + `symbolReferences()`). Slice B onward
//  will route generator decisions through that view; nothing reads
//  it yet, so the API surface is unchanged for existing callers.
//

import Foundation

public struct Expression: Hashable, Sendable {
  public let source: String
  public init(_ source: String) { self.source = source }
}

extension Expression: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self.source = value
  }
}

extension Expression {
  /// Parse `source` into the internal `ExpressionNode` AST. Throws if
  /// the source isn't a well-formed v1.5-subset Stan expression.
  /// Slice A is purely additive — no generator code reads this yet.
  internal func parsed() throws -> ExpressionNode {
    try ExpressionParser.parse(source)
  }

  /// Parse and walk in one call. Returns every named symbol the
  /// expression references, tagged with whether it appears as
  /// `name[...]` and whether it lives inside another `[...]`.
  internal func symbolReferences() throws -> Set<SymbolUse> {
    try parsed().symbolReferences()
  }
}
