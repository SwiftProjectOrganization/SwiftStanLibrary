//
//  getOptimizeResult.swift
//
//
//  Created by Robert Goedman on 11/20/25.
//
//  V2.1 follow-up (2026-05-29): split the raw cmdstan output from the
//  cleaned post-processed version into separate files. cmdstan writes
//  `<name>_optimize.csv` with `#` comment-line metadata; we read it
//  and write the comment-stripped version to `<name>.optimize.csv`.
//  Matches the existing samples convention (`<name>_output_N.csv`
//  raw, `<name>.samples.csv` clean). Also means
//  `<name>_optimize.csv` is always a valid `mode=` source for
//  cmdstan's `laplace` subcommand — the previous in-place overwrite
//  was the trap behind the laplace bug.
//

import Foundation

func getOptimizeResult(dirUrl: URL,
                              modelName: String) -> (String, String) {

  let fileManager = FileManager.default
  let rawPath = dirUrl.path + "/" + modelName + "_optimize.csv"
  let cleanPath = dirUrl.path + "/" + modelName + ".optimize.csv"

  guard fileManager.fileExists(atPath: rawPath) else {
    return ("", "\(modelName)_optimize.csv not found.")
  }

  var lines: [String] = []
  do {
    let data = try String(contentsOfFile: rawPath, encoding: .utf8)
    for line in data.components(separatedBy: .newlines) where !line.isEmpty {
      if line[line.startIndex] != "#" {
        lines.append(line)
      }
    }
  } catch {
    return ("", error.localizedDescription)
  }

  do {
    if fileManager.fileExists(atPath: cleanPath) {
      try fileManager.removeItem(atPath: cleanPath)
    }
  } catch {
    return ("", "Error removing existing \(modelName).optimize.csv: \(error)")
  }

  let csv = lines.map { $0 + "\n" }.joined()
  let cleanURL = URL(fileURLWithPath: cleanPath)
  do {
    try csv.write(to: cleanURL, atomically: true, encoding: .utf8)
  } catch {
    return ("", "Error writing \(modelName).optimize.csv: \(error)")
  }

  return ("Wrote cleaned \(modelName).optimize.csv (raw \(modelName)_optimize.csv preserved)", "")
}
