//
//  Pathfinder.swift
//
//
//  Created by Robert Goedman on 11/17/25.
//

import Foundation

public func pathfinder(model: String = "bernoulli",
                       arguments: [String] = [],
                       cmdstan: String,
                       verbose: Bool = false,
                       caseRoot: URL? = nil) -> (String, String) {

  let dirUrl = casePaths(for: model, root: caseRoot).results

  var result = stanPathfinder(dirUrl: dirUrl,
                              modelName: model,
                              cmdstan: cmdstan,
                              verbose: verbose)

  printResult(result)

  if result.1 == "" {
    result = getPathfinderResult(dirUrl: dirUrl,
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
