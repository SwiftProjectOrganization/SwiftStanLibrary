//
//  Stancode.swift
//  Stan
//
//  Slice γ of Docs/StancodeCommandPlan.md. CLI-side wrapper for the
//  in-process alist → UlamModel → stancode fast path. Reads
//  `Preliminaries/<name>.alist.R`, runs the alist parser chain
//  (lex → parse → lower → classify → AlistToUlamModel), then calls
//  the existing `stancode(_: UlamModel) throws -> String` generator
//  and writes `Results/<name>.stan`.
//
//  Skips the smoke-driver hop entirely — no swiftc, no subprocess.
//  The hand-authored `.ulam.swift` workflow stays first-class via
//  `dsl2stan`; this command is the fast alternative for users who
//  author in R via `.alist.R`.
//

import Foundation

public enum StancodeError: Error, CustomStringConvertible {
  case alistNotFound(path: String)
  case stage(String, message: String)
  case writeFailed(URL, underlying: Error)

  public var description: String {
    switch self {
    case .alistNotFound(let path):
      return "stancode: \(path) not found"
    case .stage(let stage, let message):
      return "stancode/\(stage): \(message)"
    case .writeFailed(let url, let e):
      return "stancode: could not write \(url.path): \(e)"
    }
  }
}

/// Top-level entry for the `stancode` CLI subcommand. Overloads on
/// `(_ model: UlamModel)` cleanly — the label `model:` disambiguates.
@discardableResult
public func stancode(model: String, verbose: Bool = false) throws -> URL {
  let paths = casePaths(for: model)
  try ensureCaseDirectories(paths, verbose: verbose)

  let alistURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")
  guard FileManager.default.fileExists(atPath: alistURL.path) else {
    throw StancodeError.alistNotFound(path: alistURL.path)
  }

  let source = try String(contentsOf: alistURL, encoding: .utf8)

  let parsed: [AlistStatement]
  do { parsed = try AlistParser.parse(source) }
  catch { throw StancodeError.stage("parse", message: "\(error)") }

  let lowered: [LoweredAlistStatement]
  do { lowered = try AlistLowering.lower(parsed) }
  catch { throw StancodeError.stage("lower", message: "\(error)") }

  let classified: ClassifiedAlist
  do { classified = try AlistClassify.classify(lowered) }
  catch { throw StancodeError.stage("classify", message: "\(error)") }

  let ulamModel = AlistToUlamModel.build(classified)

  let stanSource: String
  do { stanSource = try stancode(ulamModel) }
  catch { throw StancodeError.stage("generate", message: "\(error)") }

  let outURL = paths.results.appendingPathComponent("\(model).stan")
  do {
    try stanSource.write(to: outURL, atomically: true, encoding: .utf8)
  } catch {
    throw StancodeError.writeFailed(outURL, underlying: error)
  }
  if verbose { print("stancode: wrote \(outURL.path)") }

  // Side-file: model-known scalar-int constants (e.g. the multivariate
  // dimension `J`) that the `.stan` data block declares but `csv2json`
  // can't derive from the CSV. Written so `csv2json` can merge them
  // into `<name>.data.json`. Remove any stale sidecar when the current
  // model has none, so a previous model definition can't inject a wrong
  // value.
  let scalarsURL = paths.results.appendingPathComponent("\(model).scalars.json")
  let scalars = stanScalars(ulamModel)
  if !scalars.isEmpty {
    try? scalars.write(to: scalarsURL, atomically: true, encoding: .utf8)
    if verbose { print("stancode: wrote \(scalarsURL.path)") }
  } else {
    try? FileManager.default.removeItem(at: scalarsURL)
  }
  return outURL
}
