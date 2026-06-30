//
//  Runinfo.swift
//  SwiftStan
//
//  CLI-side wrapper for reading `Results/<name>.config.json` (written
//  by `sample`, which renames cmdstan's `_output_config.json`) and
//  cleaning it in place (basenames, sorted keys).
//
//  Pure-Swift — no cmdstan shell-out, no `Methods/` layer entry. Same
//  shape as `csv2json` / `stancode`.
//

import Foundation

/// Top-level entry for the `runinfo` CLI subcommand. Reads
/// `Results/<name>.config.json` and rewrites it in place with absolute
/// paths stripped to basenames + sorted keys. Returns the URL of the
/// cleaned file.
@discardableResult
public func runinfo(model: String, verbose: Bool = false, caseRoot: URL? = nil) throws -> URL {
  let paths = casePaths(for: model, root: caseRoot)
  try ensureCaseDirectories(paths, verbose: verbose)

  let info = try readRunInfo(dirUrl: paths.results, modelName: model)
  if verbose {
    switch info.method {
    case .sample(let s):
      print("runinfo: \(info.modelName) — sample (chains=\(s.numChains), warmup=\(s.numWarmup), samples=\(s.numSamples))")
    case .optimize:
      print("runinfo: \(info.modelName) — optimize")
    case .laplace:
      print("runinfo: \(info.modelName) — laplace")
    case .pathfinder:
      print("runinfo: \(info.modelName) — pathfinder")
    }
  }
  return try writeCleanRunInfo(dirUrl: paths.results, modelName: model)
}
