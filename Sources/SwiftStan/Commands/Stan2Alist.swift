//
//  Stan2Alist.swift
//  Stan
//
//  Slice E of Docs/Stan2AlistCommandPlan.md. CLI-side wrapper for the
//  reverse pipeline — the inverse of `stancode`. Reads
//  `Results/<name>.stan`, runs the reverse chain
//  (StanBlockParser → StanToUlamModel → AlistTextEmitter), and writes a
//  McElreath `alist()` to `Preliminaries/<name>.alist.R`.
//
//  Valid only on idiomatic Stan this toolchain understands (the round-
//  trip / McElreath subset). Anything outside that grammar fails loud
//  rather than guessing. Non-fatal losses (dropped `generated quantities`
//  / `transformed *` blocks, stripped affine non-centering) are surfaced
//  as stderr warnings.
//
//  Overwrite guard: refuses to clobber an existing
//  `Preliminaries/<name>.alist.R` unless `force` is set — that file may
//  be hand-authored source.
//

import Foundation

public enum Stan2AlistError: Error, CustomStringConvertible {
  case stanNotFound(path: String)
  case stage(String, message: String)
  case alistExists(path: String)
  case writeFailed(URL, underlying: Error)

  public var description: String {
    switch self {
    case .stanNotFound(let path):
      return "stan2alist: \(path) not found"
    case .stage(let stage, let message):
      return "stan2alist/\(stage): \(message)"
    case .alistExists(let path):
      return "stan2alist: \(path) already exists — pass --force to overwrite"
    case .writeFailed(let url, let e):
      return "stan2alist: could not write \(url.path): \(e)"
    }
  }
}

/// Top-level entry for the `stan2alist` CLI subcommand. The inverse of
/// `stancode(model:verbose:)`.
@discardableResult
public func stan2alist(model: String,
                       verbose: Bool = false,
                       force: Bool = false) throws -> URL {
  let paths = casePaths(for: model)
  try ensureCaseDirectories(paths, verbose: verbose)

  let stanURL = paths.results.appendingPathComponent("\(model).stan")
  guard FileManager.default.fileExists(atPath: stanURL.path) else {
    throw Stan2AlistError.stanNotFound(path: stanURL.path)
  }
  let source = try String(contentsOf: stanURL, encoding: .utf8)

  let program: StanProgram
  do { program = try StanBlockParser.parse(source) }
  catch { throw Stan2AlistError.stage("parse", message: "\(error)") }

  let result: StanToUlamModel.Result
  do { result = try StanToUlamModel.build(program) }
  catch { throw Stan2AlistError.stage("reconstruct", message: "\(error)") }

  // Surface non-fatal losses (dropped blocks, etc.) on stderr.
  for warning in result.warnings {
    FileHandle.standardError.write(Data("stan2alist: warning: \(warning)\n".utf8))
  }

  let text: String
  do { text = try AlistTextEmitter.emit(result.statements) }
  catch { throw Stan2AlistError.stage("emit", message: "\(error)") }

  let outURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")
  if FileManager.default.fileExists(atPath: outURL.path), !force {
    throw Stan2AlistError.alistExists(path: outURL.path)
  }
  do {
    try text.write(to: outURL, atomically: true, encoding: .utf8)
  } catch {
    throw Stan2AlistError.writeFailed(outURL, underlying: error)
  }
  if verbose { print("stan2alist: wrote \(outURL.path)") }
  return outURL
}
