//
//  PrintResult.swift
//  Stan
//
//  Prints a (status, errorOrEmpty) tuple in a readable form: the status
//  line if non-empty, plus an "Error: <message>" line if the error slot
//  is non-empty. Replaces direct `print(result)` calls that previously
//  emitted the raw tuple representation `("status", "")`.
//
//  `printFinalResult` is a variant for the **last** print of a CLI
//  subcommand — typically a "CSV file created at: <path>." line that
//  downstream tools (SwiftStats, TabularData loaders, Numbers) pick up.
//  Adds a leading blank line and an `→ ` prefix so the actionable path
//  is easy to spot inside the run's progress chatter.
//

import Foundation

func printResult(_ result: (String, String)) {
  if !result.0.isEmpty { print(result.0) }
  if !result.1.isEmpty { print("Error: \(result.1)") }
}

func printFinalResult(_ result: (String, String)) {
  if !result.1.isEmpty {
    print("Error: \(result.1)")
    return
  }
  if !result.0.isEmpty {
    print("")
    print("→ \(result.0)")
  }
}
