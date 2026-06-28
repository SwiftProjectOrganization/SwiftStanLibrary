//
//  Alist2Dsl.swift
//  Stan
//
//  V2.1 follow-up Slice F: orchestrate the alist parser pipeline.
//  Reads `Preliminaries/<name>.alist.R`, runs the
//  lex → parse → lower → classify → emit chain, and writes the result
//  to `Preliminaries/<Name>.ulam.swift`. The capitalised stem matches
//  the dsl2stan smoke-driver naming convention.
//
//  Per `Docs/AlistParser.md`. The function is a stable Swift API for
//  the test suite and the CLI subcommand defined in `Stan.swift`.
//

import Foundation

public enum Alist2DslError: Error, CustomStringConvertible {
  case alistNotFound(path: String)
  case stage(String, message: String)
  case writeFailed(URL, underlying: Error)

  public var description: String {
    switch self {
    case .alistNotFound(let path):
      return "alist2dsl: \(path) not found"
    case .stage(let stage, let message):
      return "alist2dsl/\(stage): \(message)"
    case .writeFailed(let url, let e):
      return "alist2dsl: could not write \(url.path): \(e)"
    }
  }
}

@discardableResult
public func alist2dsl(model: String, verbose: Bool = false) throws -> URL {
  let paths = casePaths(for: model)
  try ensureCaseDirectories(paths, verbose: verbose)

  let alistURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")
  guard FileManager.default.fileExists(atPath: alistURL.path) else {
    throw Alist2DslError.alistNotFound(path: alistURL.path)
  }

  let source = try String(contentsOf: alistURL, encoding: .utf8)

  let parsed: [AlistStatement]
  do { parsed = try AlistParser.parse(source) }
  catch { throw Alist2DslError.stage("parse", message: "\(error)") }

  let lowered: [LoweredAlistStatement]
  do { lowered = try AlistLowering.lower(parsed) }
  catch { throw Alist2DslError.stage("lower", message: "\(error)") }

  let classified: ClassifiedAlist
  do { classified = try AlistClassify.classify(lowered) }
  catch { throw Alist2DslError.stage("classify", message: "\(error)") }

  let stem = capitalisedStem(model)
  let emitter = AlistEmitter(stem: stem,
                             modelName: model,
                             classified: classified)
  let swiftSource = emitter.emit()

  let outURL = paths.preliminaries.appendingPathComponent("\(stem).ulam.swift")
  do {
    try swiftSource.write(to: outURL, atomically: true, encoding: .utf8)
  } catch {
    throw Alist2DslError.writeFailed(outURL, underlying: error)
  }
  if verbose { print("alist2dsl: wrote \(outURL.path)") }
  return outURL
}

private func capitalisedStem(_ model: String) -> String {
  guard !model.isEmpty else { return model }
  let first = model.prefix(1).uppercased()
  let rest = model.dropFirst()
  return first + rest
}
