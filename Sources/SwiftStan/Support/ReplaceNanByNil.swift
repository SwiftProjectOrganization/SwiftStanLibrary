//
//  ReplaceNanByNil.swift
//  
//
//  Created by Robert Goedman on 11/13/25.
//

import Foundation

func replaceNanByNil(_ filePath: String) {
  // Step 1: Read the file content
  let fileManager = FileManager.default
  var content: String
  
  var isDirectory: ObjCBool = false
  if fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) {
    do {
      content = try String(contentsOfFile: filePath, encoding: .utf8)
    } catch {
      print("Error reading file: \(error)")
      return
    }
    
    // Step 2: Define the regex pattern
    let regexPattern = "nan" // Replace with your actual pattern
    let replacement = "-100000"
    
    // Step 3: Perform the replacement
    let modifiedContent = content.replacingOccurrences(of: regexPattern, with: replacement, options: .regularExpression)
    
    // Step 4: Write back to the file
    do {
      try modifiedContent.write(toFile: filePath, atomically: true, encoding: .utf8)
    } catch {
      print("Error writing to file: \(error)")
    }
  }
}
