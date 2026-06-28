//
//  createDotStanFileFile.swift
//
//
//  Created by Robert Goedman on 10/31/25.
//

import Foundation

func createDotStanFile(_ data: String,
                              model: String,
                              verbose: Bool = false) -> (String, String) {

  let fileManager = FileManager.default
  let dirUrl = casePaths(for: model).results

  do {
    let filePath = dirUrl.path + "/" + model + ".stan"
    let fileUrl = URL(fileURLWithPath: filePath)
    if fileManager.fileExists(atPath: filePath) {
      do {
        let fileContent = try String(contentsOf: fileUrl, encoding: .utf8)
        if fileContent == data {
          let binaryPath = dirUrl.path + "/" + model
          if fileManager.fileExists(atPath: binaryPath) {
            return ("Stan model file has not changed, no compilation needed.", "")
          } else {
            return ("Compilation needed.", "")
          }
        }
        do {
          try fileManager.removeItem(atPath: filePath)
          if verbose {
            print("\(filePath) deleted successfully, will attempt to create a new one.")
          }
        } catch {
          return ("", "Error deleting file \(filePath): \(error)")
        }
      } catch {
        return ("", "Error reading file \(filePath) (error: \(error))")
      }
    }
    do {
      try data.write(to: fileUrl, atomically: true, encoding: .utf8)
      if verbose {
        print("New Stan model file created.")
      }
      return ("Compilation needed.", "")

    } catch {
      return ("", "Error creating Stan model file: \(error)")
    }
  }
}
