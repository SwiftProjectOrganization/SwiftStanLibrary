//
//  Csv2Json.swift
//  Stan
//
//  V2.1 Slice C: read `Preliminaries/<name>.csv`, validate column
//  coverage against `Results/<name>.stan`'s data block, derive the
//  cardinality scalars (`N`, `N_<col>`), and write
//  `Results/<name>.data.json`.
//
//  The schema source-of-truth is the generated `.stan`. csv2json
//  therefore runs *after* dsl2stan in the V2.1 orchestrator.
//
//  Any `NA` (or unparseable value) in a column the schema declares as
//  row data fails loudly with the offending column name and row number
//  — no silent drop, no NaN propagation.
//

import Foundation

public enum Csv2JsonError: Error, CustomStringConvertible {
  case csvNotFound(path: String)
  case stanNotFound(path: String)
  case schemaColumnMissing(column: String, csvPath: String)
  case naValue(column: String, row: Int, value: String)
  case nonInteger(column: String, row: Int, value: String)
  case nonReal(column: String, row: Int, value: String)
  case mixedTypeIndexColumn(column: String, row: Int, value: String)
  case schemaError(StanSchemaParseError)

  public var description: String {
    switch self {
    case .csvNotFound(let path):
      return "csv2json: CSV not found at \(path)"
    case .stanNotFound(let path):
      return "csv2json: Stan source not found at \(path); run `dsl2stan` first"
    case .schemaColumnMissing(let column, let csvPath):
      return "csv2json: schema requires column '\(column)' but it is not present in \(csvPath)"
    case .naValue(let column, let row, let value):
      return "csv2json: NA-like value '\(value)' in column '\(column)' at row \(row); drop or fix the input"
    case .nonInteger(let column, let row, let value):
      return "csv2json: non-integer value '\(value)' in column '\(column)' at row \(row)"
    case .nonReal(let column, let row, let value):
      return "csv2json: non-numeric value '\(value)' in column '\(column)' at row \(row)"
    case .mixedTypeIndexColumn(let column, let row, let value):
      return "csv2json: column '\(column)' has both string-valued rows and integer-valued ones (row \(row) = '\(value)'); auto-factorisation only fires when every value is a string"
    case .schemaError(let err):
      return "csv2json: \(err.description)"
    }
  }
}

@discardableResult
public func csv2json(model: String, verbose: Bool = false, caseRoot: URL? = nil) throws -> URL {
  let paths = casePaths(for: model, root: caseRoot)
  try ensureCaseDirectories(paths, verbose: verbose)

  let csvURL = paths.preliminaries.appendingPathComponent("\(model).csv")
  let stanURL = paths.results.appendingPathComponent("\(model).stan")
  let fm = FileManager.default
  guard fm.fileExists(atPath: csvURL.path) else {
    throw Csv2JsonError.csvNotFound(path: csvURL.path)
  }
  guard fm.fileExists(atPath: stanURL.path) else {
    throw Csv2JsonError.stanNotFound(path: stanURL.path)
  }

  let stanSource = try String(contentsOf: stanURL, encoding: .utf8)
  let schema: StanDataSchema
  do {
    schema = try parseStanDataSchema(source: stanSource)
  } catch let err as StanSchemaParseError {
    throw Csv2JsonError.schemaError(err)
  }

  let rawCsv = try String(contentsOf: csvURL, encoding: .utf8)
  let parsed = parseCsv(rawCsv)
  if verbose {
    print("csv2json: parsed \(parsed.rowCount) rows × \(parsed.headers.count) columns from \(csvURL.lastPathComponent)")
  }

  var output: [String: Any] = [:]
  /// 2026-06-08: any integer column that got auto-factorised from
  /// strings deposits its `level → 1-based int` map here. Written to
  /// `Results/<name>.factors.json` as a post-processed side artifact
  /// so analysts can recover the original string labels for plotting
  /// / interpretation.
  var factorMaps: [String: [String: Int]] = [:]

  // Required row-data columns must exist in the CSV.
  for decl in schema.declarations {
    switch decl.kind {
    case .rowCount:
      output["N"] = parsed.rowCount
    case .cardinality(let col):
      guard let column = parsed.column(named: col) else {
        // Cardinality references a column we don't have — let the user
        // fix the schema or rename.
        throw Csv2JsonError.schemaColumnMissing(column: col, csvPath: csvURL.path)
      }
      // `parseIntColumn` is deterministic on the same input array, so
      // calling it twice (once here, once in the .rowInt arm) produces
      // identical maps. The .rowInt arm is where the factor map is
      // captured — this arm only needs the integer values for the
      // `max(...)` cardinality derivation.
      let (ints, _) = try parseIntColumn(column, columnName: col)
      output[decl.name] = ints.max() ?? 0
    case .rowInt:
      guard let column = parsed.column(named: decl.name) else {
        throw Csv2JsonError.schemaColumnMissing(column: decl.name, csvPath: csvURL.path)
      }
      let (ints, factors) = try parseIntColumn(column, columnName: decl.name)
      output[decl.name] = ints
      if let factors { factorMaps[decl.name] = factors }
    case .rowReal:
      guard let column = parsed.column(named: decl.name) else {
        throw Csv2JsonError.schemaColumnMissing(column: decl.name, csvPath: csvURL.path)
      }
      output[decl.name] = try parseRealColumn(column, columnName: decl.name)
    case .other:
      continue
    }
  }

  // Merge model-known scalar-int constants (e.g. the multivariate
  // dimension `J`) that `stancode`/`dsl2stan` recorded in a sidecar.
  // These are declared in the `.stan` data block but aren't CSV columns,
  // so they can't be derived here. Only inject scalars the schema
  // actually declares (and that weren't already derived), so cmdstan
  // gets exactly the variables its data block expects.
  let scalarsURL = paths.results.appendingPathComponent("\(model).scalars.json")
  if let scalarsData = try? Data(contentsOf: scalarsURL),
     let scalarObj = try? JSONSerialization.jsonObject(with: scalarsData) as? [String: Any] {
    for (key, value) in scalarObj
    where output[key] == nil && schema.declaration(named: key) != nil {
      output[key] = value
      if verbose { print("csv2json: merged scalar constant \(key) from sidecar") }
    }
  }

  let outURL = paths.results.appendingPathComponent("\(model).data.json")
  let json = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
  try json.write(to: outURL, options: .atomic)
  if verbose { print("csv2json: wrote \(outURL.path)") }

  // Side-file: persist factor maps only when at least one column was
  // factorised. Keeps the Results/ dir clean for purely-numeric inputs.
  if !factorMaps.isEmpty {
    let factorsURL = paths.results.appendingPathComponent("\(model).factors.json")
    let factorsJSON = try JSONSerialization.data(
      withJSONObject: factorMaps,
      options: [.prettyPrinted, .sortedKeys])
    try factorsJSON.write(to: factorsURL, options: .atomic)
    if verbose {
      let cols = factorMaps.keys.sorted().joined(separator: ", ")
      print("csv2json: auto-factorised string columns [\(cols)] → \(factorsURL.lastPathComponent)")
    }
  }
  return outURL
}

// MARK: - CSV parsing

private struct ParsedCsv {
  let headers: [String]
  let rows: [[String]]
  var rowCount: Int { rows.count }

  func column(named name: String) -> [String]? {
    guard let idx = headers.firstIndex(of: name) else { return nil }
    return rows.map { idx < $0.count ? $0[idx] : "" }
  }
}

private func parseCsv(_ raw: String) -> ParsedCsv {
  let lines = raw
    .split(whereSeparator: \.isNewline)
    .map(String.init)
    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  guard let header = lines.first else { return ParsedCsv(headers: [], rows: []) }
  let delimiter: Character = header.contains(";") ? ";" : ","
  let quotes = CharacterSet(charactersIn: "\"")
  let headers = header.split(separator: delimiter, omittingEmptySubsequences: false).map {
    String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes)
  }
  let rows = lines.dropFirst().map { line in
    line.split(separator: delimiter, omittingEmptySubsequences: false).map {
      String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes)
    }
  }
  return ParsedCsv(headers: headers, rows: rows)
}

// MARK: - Column parsers (with NA detection)

private let naTokens: Set<String> = ["NA", "na", "N/A", "n/a", "NaN", "nan", ""]

/// 2026-06-08: returns the integer values plus an optional factor map
/// (level → 1-based int) when the column was auto-factorised from
/// strings (cf. McElreath's `rethinking::coerce_index`).
///
/// Behaviour:
/// - NA-like values always throw `naValue` (first occurrence).
/// - Fully-integer column → integers verbatim, factors = nil.
/// - Fully-string column with no NAs → factorise (first-seen-gets-1).
/// - Mixed integer + string (at least one of each) → throw
///   `mixedTypeIndexColumn` pointing at the integer-shaped row that
///   broke the otherwise-string column. Genuine data bugs surface
///   instead of silently factorising.
private func parseIntColumn(_ values: [String],
                            columnName: String)
    throws -> (ints: [Int], factors: [String: Int]?) {
  // Phase 1: NA detection. Always an error — McElreath's coerce_index
  // doesn't silently bucket NAs either.
  for (i, v) in values.enumerated() {
    if naTokens.contains(v) {
      throw Csv2JsonError.naValue(column: columnName, row: i + 1, value: v)
    }
  }
  // Phase 2: try parsing all as Int. Happy path for genuinely integer
  // columns — no factor map.
  let parsedInts = values.map { Int($0) }
  if parsedInts.allSatisfy({ $0 != nil }) {
    return (parsedInts.map { $0! }, nil)
  }
  // Phase 3: mixed-shape detection. At least one value is non-Int (we
  // just left the all-Int happy path); if any value IS Int, the column
  // is structurally ambiguous — surface the integer-looking row that
  // broke the otherwise-string column.
  for (i, v) in values.enumerated() where Int(v) != nil {
    throw Csv2JsonError.mixedTypeIndexColumn(
      column: columnName, row: i + 1, value: v)
  }
  // Phase 4: fully string-valued — auto-factorise. First-seen-gets-1
  // preserves the natural CSV row order, so `factors.json` reads in
  // discovery order.
  var seen: [String: Int] = [:]
  var ints: [Int] = []
  ints.reserveCapacity(values.count)
  var nextId = 1
  for v in values {
    if let id = seen[v] {
      ints.append(id)
    } else {
      seen[v] = nextId
      ints.append(nextId)
      nextId += 1
    }
  }
  return (ints, seen)
}

private func parseRealColumn(_ values: [String], columnName: String) throws -> [Double] {
  var out: [Double] = []
  out.reserveCapacity(values.count)
  for (i, v) in values.enumerated() {
    if naTokens.contains(v) {
      throw Csv2JsonError.naValue(column: columnName, row: i + 1, value: v)
    }
    guard let parsed = Double(v) else {
      throw Csv2JsonError.nonReal(column: columnName, row: i + 1, value: v)
    }
    out.append(parsed)
  }
  return out
}
