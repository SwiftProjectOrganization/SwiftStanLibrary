//
//  AlistLexer.swift
//  Stan
//
//  Slice A of the alist parser: tokenize R `alist(...)` source. Mirrors
//  `Generator/ExpressionLexer.swift` but adds the statement-level
//  tokens (`~`, `<-`, `,`) and handles R `#` comments.
//
//  T1 (Docs/AlistTransposePlan.md): `'` (apostrophe / transpose) is now
//  recognised as a `.prime` token rather than throwing
//  `unexpectedCharacter`. The token is consumed by `parseBracketVectorArg`
//  in `AlistParser` when it appears immediately after a `]` in a
//  distribution-arg position.
//

import Foundation

internal struct AlistToken: Equatable {
  internal enum Kind: Equatable {
    case identifier
    case integerLiteral
    case floatLiteral
    case plus, minus, star, slash
    case leftParen, rightParen, leftBracket, rightBracket
    case tilde       // `~`
    case assign      // `<-`
    case comma
    case equals      // `=` — only used for `data=d` style outer-call args, which we skip
    case prime       // `'` — postfix transpose (T1)
    case eof
  }

  internal let kind: Kind
  internal let lexeme: String
  internal let position: Int
}

internal enum AlistLexerError: Error, Equatable, CustomStringConvertible {
  case unexpectedCharacter(Character, position: Int)
  case invalidNumericLiteral(String, position: Int)

  internal var description: String {
    switch self {
    case .unexpectedCharacter(let c, let pos):
      return "AlistLexer: unexpected character '\(c)' at position \(pos)"
    case .invalidNumericLiteral(let s, let pos):
      return "AlistLexer: invalid numeric literal '\(s)' at position \(pos)"
    }
  }
}

internal enum AlistLexer {
  internal static func tokenize(_ source: String) throws -> [AlistToken] {
    var tokens: [AlistToken] = []
    let chars = Array(source)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c.isWhitespace {
        i += 1
        continue
      }
      // `#` to end-of-line — R-style comment, stripped silently.
      if c == "#" {
        while i < chars.count, chars[i] != "\n" { i += 1 }
        continue
      }
      // `<-` two-character operator.
      if c == "<", i + 1 < chars.count, chars[i + 1] == "-" {
        tokens.append(AlistToken(kind: .assign, lexeme: "<-", position: i))
        i += 2
        continue
      }
      // Identifier: [A-Za-z_.][A-Za-z0-9_.]* — R allows `.` in identifiers but
      // alist examples in McElreath stick to `_` style, so we permit but don't
      // require `.`. Numerics that lead with `.` are handled below.
      if c.isLetter || c == "_" {
        let start = i
        while i < chars.count,
              chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "." {
          i += 1
        }
        let lexeme = String(chars[start..<i])
        tokens.append(AlistToken(kind: .identifier, lexeme: lexeme, position: start))
        continue
      }
      // Numeric literal — same shape as ExpressionLexer.
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
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
          } else {
            break
          }
        }
        let lexeme = String(chars[start..<i])
        let kind: AlistToken.Kind = (sawDot || sawExponent) ? .floatLiteral : .integerLiteral
        if kind == .floatLiteral, Double(lexeme) == nil {
          throw AlistLexerError.invalidNumericLiteral(lexeme, position: start)
        }
        if kind == .integerLiteral, Int(lexeme) == nil {
          throw AlistLexerError.invalidNumericLiteral(lexeme, position: start)
        }
        tokens.append(AlistToken(kind: kind, lexeme: lexeme, position: start))
        continue
      }
      // Single-character punctuation.
      let single: AlistToken.Kind?
      switch c {
      case "+": single = .plus
      case "-": single = .minus
      case "*": single = .star
      case "/": single = .slash
      case "(": single = .leftParen
      case ")": single = .rightParen
      case "[": single = .leftBracket
      case "]": single = .rightBracket
      case "~": single = .tilde
      case ",": single = .comma
      case "=": single = .equals
      case "'": single = .prime   // T1: postfix transpose
      default:  single = nil
      }
      if let kind = single {
        tokens.append(AlistToken(kind: kind, lexeme: String(c), position: i))
        i += 1
        continue
      }
      throw AlistLexerError.unexpectedCharacter(c, position: i)
    }
    tokens.append(AlistToken(kind: .eof, lexeme: "", position: chars.count))
    return tokens
  }
}
