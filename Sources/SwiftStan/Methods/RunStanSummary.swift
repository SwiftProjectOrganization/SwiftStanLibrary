//
//  StanSummary.swift
//
//
//  Created by Robert Goedman on 10/30/25.
//
//  V2.1 follow-up (2026-05-29): the raw cmdstan stansummary output
//  now lands at `<name>_stansummary.csv` (was `<name>_summary.csv`)
//  so the `_raw` / `.clean` split convention is uniform with
//  optimize/laplace/pathfinder. The post-processor in
//  `ExtractStanSummary.swift` reads it and writes the cleaned
//  `<name>.stansummary.csv` alongside.
//

import Foundation

func stanSummary(dirUrl: URL,
                        modelName: String,
                        cmdstan: String) -> (String, String) {
  let fileManager = FileManager.default
  let filePath = dirUrl.path + "/" + modelName + "_stansummary.csv"

  do {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) {
      try fileManager.removeItem(atPath: filePath)
    }
  } catch {
    print("Error deleting file \(modelName)_stansummary.csv: \(error)")
  }

  // 2026-06-02: glob the chain files actually written by cmdstan rather
  // than hard-coding `_output_1..4.csv`. Handles arbitrary `num_chains`
  // values supplied via trailing args, plus partial runs where some
  // chains diverged — summarise whatever is on disk.
  let chains = chainsFromRunInfo(dirUrl: dirUrl, modelName: modelName)
            ?? chainOutputFiles(dirUrl: dirUrl, modelName: modelName)
  if chains.isEmpty {
    return ("", "stansummary: no `\(modelName)_output*.csv` files found in \(dirUrl.path)")
  }
  let result = swiftSyncFileExec(program: cmdstan + "/bin/stansummary",
                                 arguments: chains.map(\.path)
                                   + ["--csv_filename", filePath],
                                 method: "stansummary",
                                 logsDir: dirUrl,
                                 logsBase: "\(modelName).stansummary")
  return result
}

/// Authoritative chain-file list derived from
/// `<name>.config.json` (`StanSample` renames cmdstan's emitted
/// `_output_config.json` to this canonical name after each run).
/// Honours the `id` offset so batched-run workflows
/// (chains 5..7 in a second invocation) get the right URLs back, not
/// chains 1..3. Returns the URLs that *exist on disk*, in id order; a
/// partial run (4 expected, 3 present) returns the 3 and prints a
/// one-line warning so the user can spot the discrepancy.
///
/// Returns `nil` when the config is missing / unreadable / non-sample
/// / yields zero present URLs — caller should fall back to
/// `chainOutputFiles(...)`, which globs whatever happens to be on
/// disk (the pre-runinfo behaviour). Together: runinfo-first,
/// glob-backup.
func chainsFromRunInfo(dirUrl: URL, modelName: String) -> [URL]? {
  guard let info = try? readRunInfo(dirUrl: dirUrl, modelName: modelName),
        case .sample(let s) = info.method else { return nil }
  let fm = FileManager.default
  let urls: [URL]
  if s.numChains == 1 {
    urls = [dirUrl.appendingPathComponent("\(modelName)_output.csv")]
  } else {
    urls = (0..<s.numChains).map { offset in
      dirUrl.appendingPathComponent(
        "\(modelName)_output_\(info.id + offset).csv")
    }
  }
  let present = urls.filter { fm.fileExists(atPath: $0.path) }
  if present.isEmpty { return nil }
  if present.count < s.numChains {
    print("warning: \(modelName): runinfo declared num_chains=\(s.numChains) (starting at id \(info.id)), but only \(present.count) chain output file(s) found on disk — summarising the available subset.")
  }
  return present
}

/// Enumerate cmdstan's per-chain output files for a model, in chain-id
/// order. cmdstan writes `<name>_output.csv` for `num_chains=1` and
/// `<name>_output_<N>.csv` for `num_chains>1`. Globbing both patterns
/// means downstream stansummary / samples-cleanup don't need to know
/// the chain count up front. Sort is numeric on the trailing chain id
/// so 10+ chains don't reorder ahead of single-digits.
///
/// Matching is **case-insensitive** because the default macOS APFS
/// volume is case-preserving but case-insensitive: a file originally
/// created as `bernoulli_output_1.csv` keeps that display name even
/// when the binary now writes through `Bernoulli_output_1.csv`. A
/// case-sensitive `hasPrefix` would miss the stale-cased entries and
/// the post-sample glob would return empty.
func chainOutputFiles(dirUrl: URL, modelName: String) -> [URL] {
  let fm = FileManager.default
  guard let entries = try? fm.contentsOfDirectory(atPath: dirUrl.path) else {
    return []
  }
  let singleLower = "\(modelName)_output.csv".lowercased()
  let multiPrefixLower = "\(modelName)_output_".lowercased()
  let candidates = entries.filter { name in
    let lower = name.lowercased()
    return lower == singleLower
        || (lower.hasPrefix(multiPrefixLower) && lower.hasSuffix(".csv"))
  }
  return candidates
    .sorted { lhs, rhs in chainId(lhs, multiPrefix: multiPrefixLower)
                       < chainId(rhs, multiPrefix: multiPrefixLower) }
    .map { dirUrl.appendingPathComponent($0) }
}

/// Extract the chain id from a chain-output filename. `_output.csv` →
/// 0; `_output_<N>.csv` → N. Unparseable trailing components return
/// `Int.max` so they sort to the end and don't shift earlier files.
/// `multiPrefix` is the lowercased multi-chain prefix; the filename is
/// lowercased for comparison so case-mixed inputs sort correctly.
private func chainId(_ filename: String, multiPrefix: String) -> Int {
  let lower = filename.lowercased()
  guard lower.hasPrefix(multiPrefix) else { return 0 }
  let middle = lower
    .dropFirst(multiPrefix.count)
    .dropLast(".csv".count)
  return Int(middle) ?? .max
}
