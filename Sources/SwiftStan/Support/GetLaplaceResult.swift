//
//  GetLaplaceResult.swift
//  Stan
//
//  Slice γ of Docs/Planning docs/LaplaceCommandPlan.md (refactored
//  2026-05-29 to match the optimize split).
//
//  Reads the raw cmdstan output at `<name>_laplace.csv` and writes
//  the comment-stripped version to a sibling `<name>.laplace.csv`
//  (dot). The raw file is preserved unchanged, matching the
//  GetOptimizeResult convention and the samples convention
//  (`<name>_output_N.csv` raw, `<name>.samples.csv` clean).
//

import Foundation

func getLaplaceResult(dirUrl: URL,
                             modelName: String) -> (String, String) {

  let fileManager = FileManager.default
  let rawPath = dirUrl.path + "/" + modelName + "_laplace.csv"
  let cleanPath = dirUrl.path + "/" + modelName + ".laplace.csv"

  guard fileManager.fileExists(atPath: rawPath) else {
    return ("", "\(modelName)_laplace.csv not found.")
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
    return ("", "Error removing existing \(modelName).laplace.csv: \(error)")
  }

  let csv = lines.map { $0 + "\n" }.joined()
  let cleanURL = URL(fileURLWithPath: cleanPath)
  do {
    try csv.write(to: cleanURL, atomically: true, encoding: .utf8)
  } catch {
    return ("", "Error writing \(modelName).laplace.csv: \(error)")
  }

  return ("Wrote cleaned \(modelName).laplace.csv (raw \(modelName)_laplace.csv preserved)", "")
}
