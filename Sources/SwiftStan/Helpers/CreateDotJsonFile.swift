//
//  CreateDotJsonFile.swift
//  Stan
//
//  Created by Robert Goedman on 11/22/25.
//

import Foundation

func createDotJsonFile<T: Encodable>(_ data: T,
                                            model: String,
                                            kind: String = "data") -> (String, String) {
  let fileManager = FileManager.default
  let dirUrl = casePaths(for: model).results
  let filePath = dirUrl.path + "/" + model + "." + kind + ".json"

  do {
    if fileManager.fileExists(atPath: filePath) {
      try fileManager.removeItem(atPath: filePath)
    }
  } catch {
    return ("", "Error deleting file \(filePath): \(error).")
  }

  let fileURL = URL(fileURLWithPath: filePath)

  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  var jsonString: String? = ""

  do {
    let jsonData = try encoder.encode(data)
    jsonString = String(data: jsonData, encoding: .utf8) ?? nil
  } catch {
    print("Error encoding input data: \(error)")
    return ("", "Failed to encode to Json string")
  }

  do {
    try jsonString!.write(to: fileURL, atomically: true, encoding: .utf8)
    return ("Json file created at: \(fileURL.path).", "")
  } catch {
    return ("", "Error creating Json file: \(error).")
  }
}
