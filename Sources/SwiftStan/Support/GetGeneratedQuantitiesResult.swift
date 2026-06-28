//
//  GetGenerated_QuantitiesResult.swift
//
//  Merges per-chain `<name>_gq_<i>.csv` raw outputs (written by
//  stanGenerated_Quantities) into a single clean
//  `<name>.generated_quantities.csv`. Strips `#` comment lines;
//  keeps the header from chain 1 and all data rows from all chains.
//  Raw files are left intact.
//

import Foundation

func getGenerated_QuantitiesResult(dirUrl: URL,
                                         modelName: String,
                                         chainCount: Int) -> (String, String) {
  var theResult: [String] = []

  for i in 1...chainCount {
    let rawPath = dirUrl.path + "/" + modelName + "_gq_\(i).csv"
    guard FileManager.default.fileExists(atPath: rawPath) else {
      return ("", "\(modelName)_gq_\(i).csv not found.")
    }
    do {
      var count = 0
      let data = try String(contentsOfFile: rawPath, encoding: .utf8)
      for line in data.components(separatedBy: .newlines) {
        if line.isEmpty { continue }
        if line.first == "#" { continue }
        if i == 1 || count > 0 {
          theResult.append(line)
        }
        count += 1
      }
    } catch {
      return ("", "Error: \(error.localizedDescription)")
    }
  }

  return createDotCsvFile(from: theResult,
                          dirUrl: dirUrl,
                          modelName: modelName,
                          kind: "generated_quantities")
}
