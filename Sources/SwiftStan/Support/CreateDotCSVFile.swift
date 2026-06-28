//
//  createDotCsvFileFile.swift
//  
//
//  Created by Robert Goedman on 10/31/25.
//

import Foundation

func createDotCsvFile(from data: [String],
                      dirUrl: URL,
                      modelName: String,
                      kind: String) -> (String, String) {
  let fileManager = FileManager.default
  let filePath: String? = dirUrl.path + "/" + modelName + "." + kind + ".csv"

  do {
    if fileManager.fileExists(atPath: filePath!) {
      try fileManager.removeItem(atPath: filePath!)
    }
  } catch {
    return ("", "Error deleting file \(String(describing: filePath)): \(error).")
  }
  
  var csvString: String = ""
  
  for record in data {
    csvString.append("\(record)\n")
  }
  
  let fileURL = URL(string: "\(filePath!.description)")
  
  do {
    try csvString.write(to: fileURL!, atomically: true, encoding: .utf8)
    return ("CSV file created at: \(fileURL!).", "")
  } catch {
    return ("", "Error creating file: \(error).")
  }
}
