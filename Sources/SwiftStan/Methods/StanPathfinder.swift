//
//  StanPathfinder.swift
//  
//
//  Created by Robert Goedman on 10/30/25.
//

import Foundation

func stanPathfinder(dirUrl: URL,
                       modelName: String,
                       arguments: [String] = ["pathfinder"],
                       cmdstan: String,
                       verbose: Bool) -> (String, String) {

  var args = arguments
  args.append(contentsOf: ["data", "file=" + dirUrl.path + "/" + modelName + ".data.json"])
  args.append(contentsOf: ["output", "file=" + dirUrl.path + "/" + modelName + "_pathfinder.csv"])
  
  if verbose {
    print(args)
  }

  return swiftSyncFileExec(program: dirUrl.path + "/" + modelName,
                           arguments: args,
                           method: "pathfinder",
                           logsDir: dirUrl,
                           logsBase: "\(modelName).pathfinder")
}
