//
//  DictToJson.swift
//  Stan
//
//  Created by Claude Code on 02/08/26.
//

import Foundation

func dictToJson(dictionary: [String: Any],
                       model: String,
                       kind: String = "data",
                       verbose: Bool = false) -> (String, String) {

  let fileManager = FileManager.default
  let paths = casePaths(for: model)
  let dirUrl = paths.results
  let filePath = dirUrl.path + "/" + model + "." + kind + ".json"

  do {
    try ensureCaseDirectories(paths, verbose: verbose)
  } catch {
    return ("", "Could not create case directories for \(model): " + error.localizedDescription)
  }
  
  // Remove existing file if it exists
  do {
    if fileManager.fileExists(atPath: filePath) {
      try fileManager.removeItem(atPath: filePath)
      if verbose {
        print("Removed existing file at \(filePath)")
      }
    }
  } catch {
    return ("", "Error deleting file \(filePath): \(error).")
  }
  
  let fileURL = URL(fileURLWithPath: filePath)

  var jsonString: String? = ""

  do {
    let jsonData = try JSONSerialization.data(withJSONObject: dictionary, options: .prettyPrinted)
    jsonString = String(data: jsonData, encoding: .utf8) ?? nil
    if verbose {
      print("Dictionary successfully converted to JSON")
    }
  } catch {
    return ("", "Error converting dictionary to JSON: \(error)")
  }

  do {
    try jsonString!.write(to: fileURL, atomically: true, encoding: .utf8)
    if verbose {
      print("JSON file created at: \(fileURL.path).", "")
    }
    return ("", "")
  } catch {
    return ("", "Error creating JSON file: \(error).")
  }
}
