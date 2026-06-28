//
//  ScalarMarshaller.swift
//  Stan
//
//  2026-06-11: encode a model's compile-time scalar-int constants
//  (e.g. the multivariate dimension `J` introduced by `dmvnorm2` /
//  multi_normal priors) as a cmdstan-compatible JSON dict.
//
//  These are values the *model* knows structurally but that are not
//  CSV columns, so `csv2json` can't derive them from the data file
//  alone. `stancode` / `dsl2stan` emit them to a
//  `Results/<name>.scalars.json` sidecar which `csv2json` merges into
//  `<name>.data.json`. Counterpart to `stanInits`; mirrors the
//  `.factors.json` side-file pattern.
//

import Foundation

/// Render a model's `.scalarInt` data entries as a JSON object string
/// (`{"J":2}`), keys sorted for stable, diff-friendly output. Returns
/// an empty string when the model declares no scalar-int constants, so
/// callers can short-circuit emission.
func stanScalars(_ model: UlamModel) -> String {
  let scalars = model.data
    .compactMap { (name, col) -> (String, Int)? in
      if case .scalarInt(let value) = col { return (name, value) }
      return nil
    }
    .sorted { $0.0 < $1.0 }
  if scalars.isEmpty { return "" }
  let body = scalars.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
  return "{" + body + "}"
}
