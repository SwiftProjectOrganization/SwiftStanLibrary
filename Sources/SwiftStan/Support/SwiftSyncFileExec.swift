
//
//  SwiftSyncFileExec.swift
//
//
//  Created by Robert Goedman on 10/5/25.
//

import Foundation

func swiftSyncFileExec(program: String,
                       arguments: [String],
                       method: String = "sample",
                       logsDir: URL? = nil,
                       logsBase: String? = nil) -> (String, String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: program)
  process.arguments = arguments

  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe

  let label = method.isEmpty ? "`\(program)`" : "`\(program) \(method)`"

  do {
    try process.run()

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let outputText = String(decoding: outputData, as: UTF8.self)
    let errorRaw = String(decoding: errorData, as: UTF8.self)
    let errorText = errorRaw
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // `readDataToEndOfFile` blocks until the pipes close (which the
    // child closes on exit), but `terminationStatus` is only valid
    // once the process has actually been reaped.
    process.waitUntilExit()

    // Best-effort per-invocation log capture. Both files are always
    // written (even when empty) so a zero-byte log means "ran but
    // emitted nothing" vs missing = "didn't run". Overwrite on each
    // call — matches the `<name>_output_*.csv` wipe contract.
    if let dir = logsDir, let base = logsBase {
      let outURL = dir.appendingPathComponent("\(base).log")
      let errURL = dir.appendingPathComponent("\(base).error.log")
      try? outputText.write(to: outURL, atomically: true, encoding: .utf8)
      try? errorRaw.write(to: errURL, atomically: true, encoding: .utf8)
    }

    if process.terminationStatus != 0 {
      let detail = errorText.isEmpty
        ? "exit \(process.terminationStatus)"
        : "exit \(process.terminationStatus): \(errorText)"
      return ("", "Command \(label) failed (\(detail)).")
    }
    return ("Command \(label) completed successfully.", "")
  } catch {
    return ("", "Command error: \(error.localizedDescription)")
  }
}
