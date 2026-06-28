//
//  StanLaplace.swift
//  Stan
//
//  Slice α of Docs/Planning docs/LaplaceCommandPlan.md. Thin wrapper
//  that builds the cmdstan argv for the `laplace` inference method
//  and shells out via `swiftSyncFileExec`. Output is the raw cmdstan
//  CSV at `<name>_laplace.csv`; `GetLaplaceResult` post-processes it.
//

import Foundation

func stanLaplace(dirUrl: URL,
                        modelName: String,
                        arguments: [String] = ["laplace"],
                        cmdstan: String,
                        verbose: Bool) -> (String, String) {

  var args = arguments
  args.append(contentsOf: ["data", "file=" + dirUrl.path + "/" + modelName + ".data.json"])
  args.append(contentsOf: ["output", "file=" + dirUrl.path + "/" + modelName + "_laplace.csv"])

  if verbose {
    print(args)
  }

  return swiftSyncFileExec(program: dirUrl.path + "/" + modelName,
                           arguments: args,
                           method: "laplace",
                           logsDir: dirUrl,
                           logsBase: "\(modelName).laplace")
}
