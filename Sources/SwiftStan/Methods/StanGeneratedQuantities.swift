//
//  StanGenerated_Quantities.swift
//

import Foundation

func stanGenerated_Quantities(dirUrl: URL,
                                    modelName: String,
                                    chains: [URL],
                                    arguments: [String] = [],
                                    cmdstan: String,
                                    verbose: Bool) -> (String, String) {
  let binaryPath = "\(dirUrl.path)/\(modelName)"

  for (index, chainURL) in chains.enumerated() {
    let outputPath = "\(dirUrl.path)/\(modelName)_gq_\(index + 1).csv"
    var args = ["generate_quantities"]
    args.append(contentsOf: ["fitted_params=\(chainURL.path)"])
    args.append(contentsOf: arguments)
    args.append(contentsOf: ["data", "file=\(binaryPath).data.json"])
    args.append(contentsOf: ["output", "file=\(outputPath)"])

    if verbose {
      print(args)
    }

    let result = swiftSyncFileExec(program: binaryPath,
                                   arguments: args,
                                   method: "generate_quantities",
                                   logsDir: dirUrl,
                                   logsBase: "\(modelName).generate_quantities")
    if result.1 != "" {
      return result
    }
  }

  return ("generate_quantities completed for \(chains.count) chain(s).", "")
}
