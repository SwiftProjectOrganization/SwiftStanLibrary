//
//  DataMarshaller.swift
//  Stan
//
//  Phase 2 of the ulam port: encode an inferred-model's data columns into
//  Stan's data.json format. This mirrors what the existing
//  Helpers/CreateDotJsonDataFile.swift writes for hand-rolled models —
//  same top-level dict, ints stay ints, vectors are JSON arrays,
//  `N` is added automatically from the common vector length.
//
//  Hand-rolled rather than via JSONSerialization so that Doubles like
//  0.1 emit as "0.1" instead of "0.10000000000000001" (the shortest
//  round-trippable form, what Swift's standard print uses). Stan
//  variable names follow C-identifier rules, so key escaping isn't
//  needed.
//

import Foundation

enum DataMarshaller {
  /// Encode the inferred data as Stan-compatible JSON. Keys are sorted
  /// alphabetically for stable diffs.
  static func encodeJSON(_ inferred: InferredModel) -> Data {
    var entries: [(key: String, value: String)] = []

    if let N = inferred.N {
      entries.append(("N", String(N)))
    }

    // Phase 5: emit `N_<col>` (or user-provided countSymbol) for each
    // index column. Value is max(column) — Stan's 1-based indexing
    // expects values in [1, max].
    for (column, countSymbol) in inferred.indexColumns {
      if let col = inferred.dataVectors.first(where: { $0.name == column })?.column {
        if case .integer(let values) = col, let maxVal = values.max() {
          entries.append((countSymbol, String(maxVal)))
        }
      }
    }

    // Phase 6: emit each cardinality symbol's numeric length.
    for (symbol, length) in inferred.phaseSixCardinalitySymbols {
      entries.append((symbol, String(length)))
    }

    for (name, col) in inferred.dataVectors {
      switch col {
      case .real(let v):
        entries.append((name, "[" + v.map { String($0) }.joined(separator: ", ") + "]"))
      case .integer(let v):
        if inferred.promotedIntColumns.contains(name) {
          // Phase 5.5 Slice C: the data block declares this column as
          // `vector[N]`; emit float-shaped values so Stan accepts them.
          entries.append((name, "[" + v.map { String(Double($0)) }.joined(separator: ", ") + "]"))
        } else {
          entries.append((name, "[" + v.map { String($0) }.joined(separator: ", ") + "]"))
        }
      case .realArrayVector(_, _, let rows):
        // [[v00, v01, ...], [v10, v11, ...], ...]
        let inner = rows.map { row in
          "[" + row.map { String($0) }.joined(separator: ", ") + "]"
        }.joined(separator: ", ")
        entries.append((name, "[" + inner + "]"))
      case .realMatrix(_, _, let rows):
        // SUR Slice C: same row-major shape as realArrayVector; Stan
        // accepts `matrix[N, K]` from a 2D JSON array.
        let inner = rows.map { row in
          "[" + row.map { String($0) }.joined(separator: ", ") + "]"
        }.joined(separator: ", ")
        entries.append((name, "[" + inner + "]"))
      default:
        break
      }
    }

    for (name, col) in inferred.dataScalars {
      switch col {
      case .scalarReal(let v): entries.append((name, String(v)))
      case .scalarInt(let v): entries.append((name, String(v)))
      case .realVector(_, let v):
        entries.append((name, "[" + v.map { String($0) }.joined(separator: ", ") + "]"))
      case .realCovMatrix(_, let rows):
        let inner = rows.map { row in
          "[" + row.map { String($0) }.joined(separator: ", ") + "]"
        }.joined(separator: ", ")
        entries.append((name, "[" + inner + "]"))
      default: break
      }
    }

    entries.sort { $0.key < $1.key }
    let body = entries.map { "  \"\($0.key)\": \($0.value)" }.joined(separator: ",\n")
    let json = "{\n\(body)\n}\n"
    return Data(json.utf8)
  }
}
