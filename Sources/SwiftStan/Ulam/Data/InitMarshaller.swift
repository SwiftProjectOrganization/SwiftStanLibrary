//
//  InitMarshaller.swift
//  Stan
//
//  2026-06-02: encode user-supplied warmup inits as cmdstan-compatible
//  JSON. Counterpart to `DataMarshaller` — same hand-rolled formatting
//  rationale so Doubles round-trip cleanly (no `0.10000000000000001`
//  noise) and key order is stable for diff-friendly output.
//
//  cmdstan reads init JSON as a flat scalar dict by default; vector /
//  array / matrix inits would need extra encoding cases and are
//  deferred to v2.
//

import Foundation

enum InitMarshaller {
  /// Encode `[String: Double]` inits as cmdstan-compatible JSON with
  /// alphabetically sorted keys. Returns an empty `Data` when `values`
  /// is empty so callers can short-circuit emission cleanly.
  static func encodeJSON(_ values: [String: Double]) -> Data {
    if values.isEmpty { return Data() }
    let entries = values
      .sorted(by: { $0.key < $1.key })
      .map { "\"\($0.key)\":\(formatDouble($0.value))" }
    let body = "{" + entries.joined(separator: ",") + "}"
    return Data(body.utf8)
  }

  /// Whole-number doubles render with a trailing `.0` so cmdstan's
  /// reader keeps them as reals (e.g. `178` would be read as an int
  /// and reject the assignment to a `real mu`).
  private static func formatDouble(_ value: Double) -> String {
    if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
      return "\(Int(value)).0"
    }
    return String(value)
  }
}

/// Render a model's user-supplied warmup inits as a JSON string. Used
/// by the auto-generated smoke driver to print the init JSON to stdout
/// (after the Stan source and a separator), so `dsl2stan` can write
/// both `<name>.stan` and `<name>.init.json` from one pass. Returns
/// an empty string when the model has no `.inits(...)` statements.
func stanInits(_ model: UlamModel) throws -> String {
  let inferred = try DataInference.classify(model)
  let data = InitMarshaller.encodeJSON(inferred.initValues)
  return String(data: data, encoding: .utf8) ?? ""
}
