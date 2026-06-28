//
//  GetPathfinderResult.swift
//
//
//  Created by Robert Goedman on 11/20/25.
//
//  V2.1 follow-up (2026-05-29): matches the optimize/laplace split.
//  Reads the raw cmdstan output at `<name>_pathfinder.csv` and
//  writes the comment-stripped version to a sibling
//  `<name>.pathfinder.csv`. The raw file is preserved unchanged.
//

import Foundation

func getPathfinderResult(dirUrl: URL,
                                modelName: String) -> (String, String) {

  let fileManager = FileManager.default
  let rawPath = dirUrl.path + "/" + modelName + "_pathfinder.csv"
  let cleanPath = dirUrl.path + "/" + modelName + ".pathfinder.csv"

  guard fileManager.fileExists(atPath: rawPath) else {
    return ("", "\(modelName)_pathfinder.csv not found.")
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
    return ("", "Error removing existing \(modelName).pathfinder.csv: \(error)")
  }

  let csv = lines.map { $0 + "\n" }.joined()
  let cleanURL = URL(fileURLWithPath: cleanPath)
  do {
    try csv.write(to: cleanURL, atomically: true, encoding: .utf8)
  } catch {
    return ("", "Error writing \(modelName).pathfinder.csv: \(error)")
  }

  return ("Wrote cleaned \(modelName).pathfinder.csv (raw \(modelName)_pathfinder.csv preserved)", "")
}
