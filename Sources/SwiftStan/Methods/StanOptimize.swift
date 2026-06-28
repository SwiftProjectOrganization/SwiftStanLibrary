//
//  StanOptimize.swift
//  
//
//  Created by Robert Goedman on 10/30/25.
//

import Foundation

func stanOptimize(dirUrl: URL,
                     modelName: String,
                     arguments: [String] = [],
                     cmdstan: String,
                     verbose: Bool) -> (String, String) {
  
  var args = ["optimize"]
  args.append(contentsOf: arguments)
  args.append(contentsOf: ["data", "file=" + dirUrl.path + "/" + modelName + ".data.json"])
  args.append(contentsOf: ["output", "file=" + dirUrl.path + "/" + modelName + "_optimize.csv"])
  
  if verbose {
    print(args)
  }
  
  return swiftSyncFileExec(program: dirUrl.path + "/" + modelName,
                           arguments: args,
                           method: "optimize",
                           logsDir: dirUrl,
                           logsBase: "\(modelName).optimize")
}
