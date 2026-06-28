//
//  StanCompile.swift
//  
//
//  Created by Robert Goedman on 11/13/25.
//

import Foundation

func stanCompile(dirUrl: URL,
                        modelName: String,
                        cmdstan: String,
                        verbose: Bool) -> (String, String) {
  
  let modelPath = "\(dirUrl.path)/\(modelName)"
  
  if verbose {
    print(["/usr/bin/make", "-C \(cmdstan)", "\(modelPath)"])
  }

  let result = swiftSyncFileExec(program: "/usr/bin/make",
                                 arguments: ["-C", cmdstan, "\(modelPath)"],
                                 method: "(\(modelName) executable)",
                                 logsDir: dirUrl,
                                 logsBase: "\(modelName).compile")
  return result
}
