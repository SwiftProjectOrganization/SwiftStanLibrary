//
//  ExpressionParser.swift
//  Stan
//
//  Phase 5.5 Slice A: recursive-descent parser for `Expression.source`.
//  Pratt-style precedence climbing over the v1.5 subset (additive +
//  multiplicative + unary `-` + parens + indexing + single-arg call).
//  Public entry point: `ExpressionParser.parse(_:)`.
//

import Foundation

internal enum ExpressionParseError: Error, Equatable {
  case unexpectedToken(found: String, expected: String, position: Int)
  case unexpectedEnd(expected: String, position: Int)
  case lexerError(ExpressionLexerError)
}

internal enum ExpressionParser {
  internal static func parse(_ source: String) throws -> ExpressionNode {
    let tokens: [Token]
    do {
      tokens = try ExpressionLexer.tokenize(source)
    } catch let error as ExpressionLexerError {
      throw ExpressionParseError.lexerError(error)
    }
    var state = ParseState(tokens: tokens, cursor: 0)
    let node = try state.parseExpression()
    let trailing = state.peek()
    guard trailing.kind == .eof else {
      throw ExpressionParseError.unexpectedToken(
        found: trailing.lexeme,
        expected: "end of expression",
        position: trailing.position)
    }
    return node
  }
}

private struct ParseState {
  let tokens: [Token]
  var cursor: Int

  func peek() -> Token { tokens[cursor] }

  mutating func advance() -> Token {
    let t = tokens[cursor]
    cursor += 1
    return t
  }

  mutating func expect(_ kind: Token.Kind,
                       _ expected: String) throws -> Token {
    let t = peek()
    if t.kind == kind {
      return advance()
    }
    if t.kind == .eof {
      throw ExpressionParseError.unexpectedEnd(expected: expected,
                                               position: t.position)
    }
    throw ExpressionParseError.unexpectedToken(found: t.lexeme,
                                               expected: expected,
                                               position: t.position)
  }

  // expression  := additive
  mutating func parseExpression() throws -> ExpressionNode {
    try parseAdditive()
  }

  // additive    := multiplicative (('+'|'-') multiplicative)*
  mutating func parseAdditive() throws -> ExpressionNode {
    var left = try parseMultiplicative()
    while peek().kind == .plus || peek().kind == .minus {
      let op: BinaryOp = (advance().kind == .plus) ? .add : .subtract
      let right = try parseMultiplicative()
      left = .binary(op: op, lhs: left, rhs: right)
    }
    return left
  }

  // multiplicative := unary (('*'|'/') unary)*
  mutating func parseMultiplicative() throws -> ExpressionNode {
    var left = try parseUnary()
    while peek().kind == .star || peek().kind == .slash {
      let op: BinaryOp = (advance().kind == .star) ? .multiply : .divide
      let right = try parseUnary()
      left = .binary(op: op, lhs: left, rhs: right)
    }
    return left
  }

  // unary       := '-' unary | primary
  mutating func parseUnary() throws -> ExpressionNode {
    if peek().kind == .minus {
      _ = advance()
      let operand = try parseUnary()
      return .unary(op: .negate, operand: operand)
    }
    return try parsePrimary()
  }

  // primary     := '(' expression ')'
  //              | integerLiteral | floatLiteral
  //              | identifier ( '(' expression ')' )?    // call
  //              | identifier ( '[' expression ']' )?    // indexed
  //              | identifier
  mutating func parsePrimary() throws -> ExpressionNode {
    let t = peek()
    switch t.kind {
    case .leftParen:
      _ = advance()
      let expr = try parseExpression()
      _ = try expect(.rightParen, "')'")
      return expr

    case .integerLiteral:
      _ = advance()
      guard let v = Int(t.lexeme) else {
        throw ExpressionParseError.unexpectedToken(
          found: t.lexeme,
          expected: "integer literal",
          position: t.position)
      }
      return .literal(.integer(v))

    case .floatLiteral:
      _ = advance()
      guard let v = Double(t.lexeme) else {
        throw ExpressionParseError.unexpectedToken(
          found: t.lexeme,
          expected: "float literal",
          position: t.position)
      }
      return .literal(.float(v))

    case .identifier:
      let nameToken = advance()
      let name = nameToken.lexeme
      switch peek().kind {
      case .leftParen:
        _ = advance()
        let arg = try parseExpression()
        _ = try expect(.rightParen, "')'")
        return .call(name: name, argument: arg)
      case .leftBracket:
        _ = advance()
        let index = try parseExpression()
        // Nested groupings (2026-06-03): comma after the first index
        // → matrix-style two-arg subscript `name[i, j]`. v1 rejects
        // 3+ comma-separated indices.
        if peek().kind == .comma {
          _ = advance()
          let index2 = try parseExpression()
          if peek().kind == .comma {
            let t = peek()
            throw ExpressionParseError.unexpectedToken(
              found: t.lexeme,
              expected: "']' (3+ comma-separated indices are not supported in v1)",
              position: t.position)
          }
          _ = try expect(.rightBracket, "']'")
          return .subscript2(name: name, idx1: index, idx2: index2)
        }
        _ = try expect(.rightBracket, "']'")
        // Multivariate hierarchical priors Slice D: peek for a second
        // bracket — `name[outer][inner]` becomes a `.chainedIndexed`
        // node. Deeper nesting (a third bracket) is rejected at the
        // emitter, not here.
        if peek().kind == .leftBracket {
          _ = advance()
          let innerIndex = try parseExpression()
          _ = try expect(.rightBracket, "']'")
          return .chainedIndexed(name: name,
                                 outerIndex: index,
                                 innerIndex: innerIndex)
        }
        return .indexed(name: name, index: index)
      default:
        return .identifier(name)
      }

    case .eof:
      throw ExpressionParseError.unexpectedEnd(expected: "expression",
                                               position: t.position)

    default:
      throw ExpressionParseError.unexpectedToken(found: t.lexeme,
                                                 expected: "expression",
                                                 position: t.position)
    }
  }
}
