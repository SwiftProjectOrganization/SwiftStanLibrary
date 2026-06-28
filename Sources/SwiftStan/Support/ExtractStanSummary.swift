//
//  ExtractStanSummary.swift
//
//
//  Created by Robert Goedman on 11/14/25.
//
//  V2.1 follow-up (2026-05-29): updated to read the renamed raw
//  source at `<name>_stansummary.csv` (formerly `<name>_summary.csv`)
//  and write the cleaned output to `<name>.stansummary.csv` (dot).
//  Matches the optimize / laplace / pathfinder split.
//

import Foundation

func extractStanSummary(dirUrl: URL,
                               modelName: String) -> (String, String) {

  let fileManager = FileManager.default
  let rawPath = dirUrl.path + "/" + modelName + "_stansummary.csv"
  let cleanPath = dirUrl.path + "/" + modelName + ".stansummary.csv"

  guard fileManager.fileExists(atPath: rawPath) else {
    return ("", "\(modelName)_stansummary.csv not found.")
  }

  // cmdstan writes `nan` for undefined entries (e.g. fixed parameters
  // with zero variance). Normalise to `null` so the cleaned CSV still
  // survives a downstream JSON round-trip.
  replaceNanByNil(rawPath)

  var theResult: String = "name,mean,mcse,stddev,mad,p05,p50,p95,ess_bulk,ess_tail,ess_bulk_per_s,R_hat\n"
  do {
    let data = try String(contentsOfFile: rawPath, encoding: .utf8)
    // cmdstan's stansummary layout: line 0 is the column header,
    // then N data rows (7 sampler diagnostics + every model
    // parameter), then trailing `# ...` comment lines and a blank.
    // Keep the data rows; drop the original header (we emit a
    // lower-cased one above), the `#` comment block, and empty lines.
    for (index, line) in data.components(separatedBy: .newlines).enumerated() {
      if index == 0 { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("#") { continue }
      theResult += line + "\n"
    }
  } catch {
    return ("", error.localizedDescription)
  }

  do {
    if fileManager.fileExists(atPath: cleanPath) {
      try fileManager.removeItem(atPath: cleanPath)
    }
  } catch {
    return ("", "Error removing existing \(modelName).stansummary.csv: \(error)")
  }

  let cleanURL = URL(fileURLWithPath: cleanPath)
  do {
    try theResult.write(to: cleanURL, atomically: true, encoding: .utf8)
  } catch {
    return ("", "Error writing \(modelName).stansummary.csv: \(error)")
  }

  return ("Wrote cleaned \(modelName).stansummary.csv (raw \(modelName)_stansummary.csv preserved)", "")
}
