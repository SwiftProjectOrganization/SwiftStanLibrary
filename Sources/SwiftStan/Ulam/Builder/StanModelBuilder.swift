//
//  StanModelBuilder.swift
//  Stan
//
//  Phase 1 of the ulam port: the result-builder + the protocol DSL nodes
//  conform to. Conditional/loop support is intentionally omitted for v1;
//  it can be bolted on when multilevel models (Phase 5) need it.
//

import Foundation

public protocol ModelStatement {
  var statement: Statement { get }
}

@resultBuilder
public struct StanModelBuilder {
  public static func buildBlock(_ components: ModelStatement...) -> [Statement] {
    components.map(\.statement)
  }
}
