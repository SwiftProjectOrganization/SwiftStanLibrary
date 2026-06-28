//
//  ExpressionLexer.swift
//  Stan
//
//  Phase 5.5 Slice A: tokenizer for `Expression.source`. Internal —
//  only the ExpressionParser consumes its output. Recognises the
//  v1.5 subset of Stan expression syntax: identifiers, numeric
//  literals, `+ - * /`, parentheses, and square brackets. Anything
//  else throws.
//

import Foundation

internal struct Token: Equatable {
  internal enum Kind: Equatable {
    case identifier
    case integerLiteral
    case floatLiteral
    case plus
    case minus
    case star
    case slash
    case leftParen
    case rightParen
    case leftBracket
    case rightBracket
    case comma
    case eof
  }

  internal let kind: Kind
  internal let lexeme: String
  internal let position: Int
}

internal enum ExpressionLexerError: Error, Equatable {
  case unexpectedCharacter(Character, position: Int)
  case invalidNumericLiteral(String, position: Int)
}

internal enum ExpressionLexer {
  internal static func tokenize(_ source: String) throws -> [Token] {
    var tokens: [Token] = []
    let chars = Array(source)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c.isWhitespace {
        i += 1
        continue
      }
      // Identifier: [A-Za-z_][A-Za-z0-9_]*
      if c.isLetter || c == "_" {
        let start = i
        while i < chars.count,
              chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
          i += 1
        }
        let lexeme = String(chars[start..<i])
        tokens.append(Token(kind: .identifier, lexeme: lexeme, position: start))
        continue
      }
      // Numeric literal: integer, float (with `.` or exponent), or `.5`-style float.
      if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
        let start = i
        var sawDot = false
        var sawExponent = false
        while i < chars.count {
          let ch = chars[i]
          if ch.isNumber {
            i += 1
          } else if ch == "." && !sawDot && !sawExponent {
            sawDot = true
            i += 1
          } else if (ch == "e" || ch == "E") && !sawExponent {
            sawExponent = true
            i += 1
            if i < chars.count, chars[i] == "+" || chars[i] == "-" {
              i += 1
            }
          } else {
            break
          }
        }
        let lexeme = String(chars[start..<i])
        let kind: Token.Kind = (sawDot || sawExponent) ? .floatLiteral : .integerLiteral
        if kind == .floatLiteral, Double(lexeme) == nil {
          throw ExpressionLexerError.invalidNumericLiteral(lexeme, position: start)
        }
        if kind == .integerLiteral, Int(lexeme) == nil {
          throw ExpressionLexerError.invalidNumericLiteral(lexeme, position: start)
        }
        tokens.append(Token(kind: kind, lexeme: lexeme, position: start))
        continue
      }
      // Single-character punctuation.
      let punctuation: Token.Kind?
      switch c {
      case "+": punctuation = .plus
      case "-": punctuation = .minus
      case "*": punctuation = .star
      case "/": punctuation = .slash
      case "(": punctuation = .leftParen
      case ")": punctuation = .rightParen
      case "[": punctuation = .leftBracket
      case "]": punctuation = .rightBracket
      case ",": punctuation = .comma
      default:  punctuation = nil
      }
      if let kind = punctuation {
        tokens.append(Token(kind: kind, lexeme: String(c), position: i))
        i += 1
        continue
      }
      throw ExpressionLexerError.unexpectedCharacter(c, position: i)
    }
    tokens.append(Token(kind: .eof, lexeme: "", position: chars.count))
    return tokens
  }
}
