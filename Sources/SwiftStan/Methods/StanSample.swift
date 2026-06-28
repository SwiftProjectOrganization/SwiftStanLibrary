//
//  StanSample.swift
//  
//
//  Created by Robert Goedman on 10/30/25.
//

import Foundation

func stanSample(dirUrl: URL,
                   modelName: String,
                   arguments: [String] = ["num_chains=4"],
                   cmdstan: String,
                   verbose: Bool) -> (String, String) {
  
  
  let fileManager = FileManager.default
  let binaryPath = "\(dirUrl.path)/\(modelName)"
  if !fileManager.fileExists(atPath: binaryPath + ".data.json") {
    return ("","Input file \(binaryPath).data.json not found.")
  }

  // 2026-06-02: wipe stale `<name>_output*.csv` from any previous run
  // so a higher `num_chains` value doesn't bleed extra chains into the
  // post-sample glob in `getSampleResult` / `stanSummary`.
  for stale in chainOutputFiles(dirUrl: dirUrl, modelName: modelName) {
    try? fileManager.removeItem(at: stale)
  }
  // Wipe stale config so a failed run can't leave the previous run's
  // chain count visible to chainsFromRunInfo.
  try? fileManager.removeItem(at: dirUrl.appendingPathComponent("\(modelName).config.json"))

  var args = ["sample"]
  args.append(contentsOf: arguments)
  // 2026-06-02: auto-pick up a sibling `<name>.init.json` written by
  // the V1 `ulam()` path or by `dsl2stan` from a smoke driver that
  // declares `Inits([...])`. Disk presence is the activation trigger
  // — no extra parameter needed.
  let initPath = "\(binaryPath).init.json"
  if fileManager.fileExists(atPath: initPath) {
    args.append("init=\(initPath)")
  }
  args.append(contentsOf: ["data", "file=\(binaryPath)" + ".data.json"])
  args.append(contentsOf: ["output", "file=\(binaryPath)" + "_output.csv"])
  args.append(contentsOf: ["save_cmdstan_config=true"])
  
  if verbose {
    print(args)
  }

  let result = swiftSyncFileExec(program: binaryPath,
                                 arguments: args,
                                 method: "sample",
                                 logsDir: dirUrl,
                                 logsBase: "\(modelName).sample")

  // Rename cmdstan's `<name>_output_config.json` to `<name>.config.json`
  // so all readers (runinfo, chainsFromRunInfo) use a single canonical name.
  let rawConfig  = dirUrl.appendingPathComponent("\(modelName)_output_config.json")
  let cleanConfig = dirUrl.appendingPathComponent("\(modelName).config.json")
  if fileManager.fileExists(atPath: rawConfig.path) {
    try? fileManager.moveItem(at: rawConfig, to: cleanConfig)
  }

  return result
}
