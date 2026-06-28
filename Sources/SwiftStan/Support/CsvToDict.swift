//
//  CsvToDict.swift
//  Stan
//
//  Created by Claude Code on 02/08/26.
//

import Foundation

func csvToDict(model: String,
                      kind: String = "summary",
                      hasHeader: Bool = true,
                      delimiter: String = ",",
                      verbose: Bool = false) -> ([String: Any], String) {

  let fileManager = FileManager.default
  let dirUrl = casePaths(for: model).preliminaries
  let filePath = dirUrl.path + "/" + model + ".csv"
  
  // Check if file exists
  if !fileManager.fileExists(atPath: filePath) {
    return ([:], "CSV file not found at: \(filePath)")
  }
  
  if verbose {
    print("Reading CSV file from: \(filePath)")
  }
  
  // Read file contents
  var csvContent: String
  do {
    csvContent = try String(contentsOfFile: filePath, encoding: .utf8)
  } catch {
    return ([:], "Error reading CSV file: \(error)")
  }
  
  // Split into lines
  var lines = csvContent.components(separatedBy: .newlines)
  
  // Remove empty lines
  lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  
  if lines.isEmpty {
    return ([:], "CSV file is empty")
  }
  
  var result: [String: [Double]] = [:]
  
  if hasHeader {
    // First line contains column headers
    let headers = lines[0].components(separatedBy: delimiter)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    
    if verbose {
      print("Found \(headers.count) columns: \(headers.joined(separator: ", "))")
    }
    
    // Initialize arrays for each column
    for header in headers {
      result[header] = []
    }
    
    // Process data rows
    for i in 1..<lines.count {
      let values = lines[i].components(separatedBy: delimiter)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      
      // Add values to corresponding columns
      for (index, header) in headers.enumerated() {
        if index < values.count {
          result[header]?.append(Double(values[index])!)
        } else {
          result[header]?.append(0.0) // Handle missing values
        }
      }
    }
    
    if verbose {
      print("Successfully read \(lines.count - 1) rows")
    }
    
    return (result, "")
    
  } else {
    // No header - use numeric column names
    let firstLine = lines[0].components(separatedBy: delimiter)
    let columnCount = firstLine.count
    
    if verbose {
      print("No header found. Using \(columnCount) numeric column names")
    }
    
    // Initialize arrays for each column with numeric names
    for i in 0..<columnCount {
      result["column_\(i)"] = []
    }
    
    // Process all rows
    for line in lines {
      let values = line.components(separatedBy: delimiter)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      
      for (index, value) in values.enumerated() {
        if index < columnCount {
          (result["column_\(index)"] as AnyObject).append(value)
        }
      }
    }
    
    if verbose {
      print("Successfully read \(lines.count) rows")
    }
    
    return (result, "")
  }
}
