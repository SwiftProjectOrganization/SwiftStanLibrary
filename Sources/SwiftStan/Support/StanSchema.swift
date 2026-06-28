//
//  StanSchema.swift
//  Stan
//
//  V2.1 Slice C: minimal parser for a Stan program's `data {}` block,
//  used by `csv2json` to learn which CSV columns the model needs and
//  which scalars are derived from the data (`N` = row count, `N_<col>`
//  = max(col)).
//
//  Only the shapes the V1 generator emits are handled:
//    int<...> N;
//    int<...> N_<col>;
//    array[N] int<...> <col>;
//    array[N] real<...> <col>;
//    vector[N] <col>;
//
//  Other declarations (matrix[N, K], vector[K], etc.) are recognised
//  as "other" and ignored — csv2json doesn't try to validate them in
//  the first cut.
//

import Foundation

public struct StanDataSchema {
  public enum DeclarationKind: Equatable {
    /// `int N;` — scalar row count, derived as the number of CSV rows.
    case rowCount
    /// `int N_<col>;` — derived as max value of column `<col>`.
    case cardinality(of: String)
    /// `array[N] int<...> <col>;` — integer per-row column read from CSV.
    case rowInt
    /// `array[N] real<...> <col>;` or `vector[N] <col>;` — real per-row column.
    case rowReal
    /// Anything else (matrix, vector[K], etc.) — left alone.
    case other
  }

  public struct Declaration: Equatable {
    public let name: String
    public let kind: DeclarationKind
  }

  public let declarations: [Declaration]

  public func declaration(named: String) -> Declaration? {
    declarations.first { $0.name == named }
  }

  /// CSV column names the model expects (rowInt + rowReal).
  public var requiredColumns: [String] {
    declarations.compactMap { decl in
      switch decl.kind {
      case .rowInt, .rowReal: return decl.name
      default: return nil
      }
    }
  }
}

public enum StanSchemaParseError: Error, CustomStringConvertible {
  case dataBlockNotFound
  case malformedDeclaration(line: String)

  public var description: String {
    switch self {
    case .dataBlockNotFound:
      return "StanSchema: no `data { ... }` block found in source"
    case .malformedDeclaration(let line):
      return "StanSchema: could not parse declaration \"\(line)\""
    }
  }
}

public func parseStanDataSchema(source: String) throws -> StanDataSchema {
  guard let body = extractDataBlock(source) else {
    throw StanSchemaParseError.dataBlockNotFound
  }
  let stripped = stripStanComments(body)
  let statements = stripped
    .components(separatedBy: ";")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
  var decls: [StanDataSchema.Declaration] = []
  for raw in statements {
    let collapsed = raw.replacingOccurrences(of: "\n", with: " ")
    guard let name = lastIdentifier(in: collapsed) else {
      throw StanSchemaParseError.malformedDeclaration(line: raw)
    }
    let kind = classifyStanDeclaration(collapsed, name: name)
    decls.append(.init(name: name, kind: kind))
  }
  return StanDataSchema(declarations: decls)
}

private func extractDataBlock(_ source: String) -> String? {
  guard let dataRange = source.range(of: "data") else { return nil }
  let afterData = source[dataRange.upperBound...]
  guard let openBrace = afterData.firstIndex(of: "{") else { return nil }
  var depth = 0
  var idx = openBrace
  while idx < afterData.endIndex {
    let c = afterData[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 {
        let bodyStart = afterData.index(after: openBrace)
        return String(afterData[bodyStart..<idx])
      }
    }
    idx = afterData.index(after: idx)
  }
  return nil
}

private func stripStanComments(_ s: String) -> String {
  var out = ""
  var i = s.startIndex
  while i < s.endIndex {
    if i < s.index(before: s.endIndex), s[i] == "/", s[s.index(after: i)] == "/" {
      while i < s.endIndex, s[i] != "\n" { i = s.index(after: i) }
    } else {
      out.append(s[i])
      i = s.index(after: i)
    }
  }
  return out
}

private func lastIdentifier(in declaration: String) -> String? {
  let trimmed = declaration.trimmingCharacters(in: .whitespaces)
  let chars = Array(trimmed)
  guard !chars.isEmpty else { return nil }
  var end = chars.count
  while end > 0, !isIdentifierChar(chars[end - 1]) { end -= 1 }
  var start = end
  while start > 0, isIdentifierChar(chars[start - 1]) { start -= 1 }
  if start == end { return nil }
  return String(chars[start..<end])
}

private func isIdentifierChar(_ c: Character) -> Bool {
  c.isLetter || c.isNumber || c == "_"
}

private func classifyStanDeclaration(_ decl: String,
                                     name: String) -> StanDataSchema.DeclarationKind {
  let leading = decl.trimmingCharacters(in: .whitespaces)

  if leading.hasPrefix("array[") {
    if leading.contains(" int") { return .rowInt }
    if leading.contains(" real") { return .rowReal }
    return .other
  }
  if leading.hasPrefix("vector[N]") || leading == "vector[N] \(name)" || leading.range(of: "^vector\\[N\\]", options: .regularExpression) != nil {
    return .rowReal
  }
  // Plain scalar `int` declaration — `N`, `N_<col>`, or just other scalar.
  if leading.hasPrefix("int") {
    if name == "N" { return .rowCount }
    if name.hasPrefix("N_") {
      return .cardinality(of: String(name.dropFirst(2)))
    }
    return .other
  }
  return .other
}
