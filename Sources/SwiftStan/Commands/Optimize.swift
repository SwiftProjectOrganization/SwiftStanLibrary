//
//  Optimize.swift
//
//
//  Created by Robert Goedman on 11/17/25.
//

import Foundation

public func optimize(model: String = "bernoulli",
                     arguments: [String] = [],
                     cmdstan: String,
                     verbose: Bool = false) -> (String, String) {

  let dirUrl = casePaths(for: model).results

  let result = stanOptimize(dirUrl: dirUrl,
                            modelName: model,
                            arguments: arguments,
                            cmdstan: cmdstan,
                            verbose: verbose)

  if result.1 == "" {
    let result = getOptimizeResult(dirUrl: dirUrl,
                                   modelName: model)
    if verbose {
      printResult(result)
    }
  } else {
    printResult(result)
    return result
  }

  return result
}
