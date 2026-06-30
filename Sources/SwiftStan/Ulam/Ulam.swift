//
//  Ulam.swift
//  Stan
//
//  Two orchestrators:
//
//  - `ulam(_ model: UlamModel, ...)` — V1 in-process path. Lowers an
//    `UlamModel` value via `StanCodeGenerator.assemble` + writes both
//    .stan and .data.json, then hands off to compile + sample. Used by
//    the in-test demos and by code that already holds an `UlamModel`.
//
//  - `ulamPipeline(model: String, ...)` — V2.1 file path. Chains
//    `dsl2stan → csv2json → compile → sample` against the
//    `<root>/<name>/{Preliminaries,Results}/` layout. The `make`-style
//    staleness check skips regeneration when the inputs haven't moved.
//
//  Both write into `Results/`; the file orchestrator additionally reads
//  `Preliminaries/`.
//

import Foundation

public func ulam(_ model: UlamModel,
                 name: String = "model",
                 cmdstan: String,
                 verbose: Bool = false,
                 arguments: [String] = [],
                 caseRoot: URL? = nil) -> (String, String) {

  let stanSource: String
  let dataJSON: Data
  let initJSON: Data
  do {
    let inferred = try DataInference.classify(model)
    stanSource = try StanCodeGenerator.assemble(inferred: inferred,
                                                statements: model.statements)
    dataJSON = DataMarshaller.encodeJSON(inferred)
    initJSON = InitMarshaller.encodeJSON(inferred.initValues)
  } catch {
    return ("", "ulam: generator error: \(error)")
  }

  let paths = casePaths(for: name, root: caseRoot)
  do {
    try ensureCaseDirectories(paths, verbose: verbose)
  } catch {
    return ("", "ulam: could not create case directories: \(error.localizedDescription)")
  }

  let stanPath = paths.results.appendingPathComponent("\(name).stan")
  let dataPath = paths.results.appendingPathComponent("\(name).data.json")
  let initPath = paths.results.appendingPathComponent("\(name).init.json")
  do {
    try stanSource.write(to: stanPath, atomically: true, encoding: .utf8)
    try dataJSON.write(to: dataPath, options: .atomic)
    if verbose {
      print("Wrote \(stanPath.path)")
      print("Wrote \(dataPath.path)")
    }
    if !initJSON.isEmpty {
      try initJSON.write(to: initPath, options: .atomic)
      if verbose { print("Wrote \(initPath.path)") }
    }
  } catch {
    return ("", "ulam: file write failed: \(error.localizedDescription)")
  }

  let compileResult = compile(model: name,
                              arguments: arguments,
                              cmdstan: cmdstan,
                              verbose: verbose,
                              install: false,
                              caseRoot: caseRoot)
  if compileResult.1 != "" {
    return compileResult
  }

  return sample(model: name,
                arguments: arguments,
                cmdstan: cmdstan,
                verbose: verbose,
                nosummary: false,
                install: false,
                caseRoot: caseRoot)
}

/// V2.1 file-based orchestrator. Resolves `<root>/<name>/{Preliminaries,Results}/`
/// via `casePaths(for:root:)` and chains the four-step pipeline:
///
///   dsl2stan  ←  Preliminaries/*.ulam.swift   → Results/<name>.stan
///   csv2json  ←  Preliminaries/<name>.csv +
///                Results/<name>.stan        → Results/<name>.data.json
///   compile + sample over Results/
///
/// Each step runs only when its inputs are newer than its outputs (or
/// outputs missing). Steps with missing inputs are skipped, not errored
/// — a model with no .csv (data baked into the .ulam.swift) skips
/// csv2json silently.
public func ulamPipeline(model: String,
                         cmdstan: String,
                         verbose: Bool = false,
                         force: Bool = false,
                         arguments: [String] = [],
                         caseRoot: URL? = nil) -> (String, String) {
  let paths = casePaths(for: model, root: caseRoot)
  do {
    try ensureCaseDirectories(paths, verbose: verbose)
  } catch {
    return ("", "ulamPipeline: could not create case directories: \(error.localizedDescription)")
  }

  let fm = FileManager.default
  let stanURL = paths.results.appendingPathComponent("\(model).stan")
  let dataURL = paths.results.appendingPathComponent("\(model).data.json")
  let csvURL = paths.preliminaries.appendingPathComponent("\(model).csv")
  let alistURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")

  // 1. Path selection — option 2 from Docs/StancodeCommandPlan.md.
  //
  //    If a `<name>.alist.R` exists, prefer the in-process `stancode`
  //    fast path (`alist.R → UlamModel → .stan`). This skips the
  //    smoke-driver hop and the swiftc invocation entirely.
  //
  //    Otherwise, fall back to `dsl2stan` against a hand-authored
  //    `<Name>.ulam.swift`. Users who want the smoke driver from an
  //    alist still run `stan alist2dsl` explicitly.
  if fm.fileExists(atPath: alistURL.path) {
    if isStale(input: alistURL, output: stanURL) {
      if verbose { print("ulamPipeline: stancode (\(model).alist.R → \(model).stan)") }
      do {
        _ = try stancode(model: model, verbose: verbose, caseRoot: caseRoot)
      } catch {
        return ("", "ulamPipeline: stancode failed: \(error)")
      }
    } else if verbose {
      print("ulamPipeline: stancode skipped (\(model).stan up to date)")
    }
  } else if verbose {
    // The `.ulam.swift` → `dsl2stan` path is not available in SwiftStanLibrary
    // (it requires the package source tree to recompile via swiftc). Use
    // `alist2dsl` to generate an `alist.R` first, then re-run `ulamPipeline`.
    print("ulamPipeline: no Preliminaries/\(model).alist.R; skipping .stan generation")
  }

  // 2. csv2json if a CSV exists in Preliminaries and is newer than
  //    .data.json (requires a .stan to validate against — which step 1
  //    ensured if a driver existed).
  if fm.fileExists(atPath: csvURL.path) {
    if isStale(input: csvURL, output: dataURL) {
      if verbose { print("ulamPipeline: csv2json (\(model).csv → \(model).data.json)") }
      do {
        _ = try csv2json(model: model, verbose: verbose, caseRoot: caseRoot)
      } catch {
        return ("", "ulamPipeline: csv2json failed: \(error)")
      }
    } else if verbose {
      print("ulamPipeline: csv2json skipped (\(model).data.json up to date)")
    }
  } else if verbose {
    print("ulamPipeline: no Preliminaries/\(model).csv; skipping csv2json")
  }

  // 3. compile + sample.
  let compileResult = compile(model: model,
                              arguments: arguments,
                              cmdstan: cmdstan,
                              verbose: verbose,
                              install: false,
                              force: force,
                              caseRoot: caseRoot)
  if compileResult.1 != "" { return compileResult }

  return sample(model: model,
                arguments: arguments,
                cmdstan: cmdstan,
                verbose: verbose,
                nosummary: false,
                install: false,
                caseRoot: caseRoot)
}

private func isStale(input: URL, output: URL) -> Bool {
  let fm = FileManager.default
  guard fm.fileExists(atPath: output.path) else { return true }
  let inputMod = (try? fm.attributesOfItem(atPath: input.path)[.modificationDate]) as? Date
  let outputMod = (try? fm.attributesOfItem(atPath: output.path)[.modificationDate]) as? Date
  guard let inDate = inputMod, let outDate = outputMod else { return true }
  return inDate > outDate
}
