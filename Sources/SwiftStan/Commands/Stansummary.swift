//
//  Stansummary.swift
//
//
//  Created by Robert Goedman on 11/17/25.
//

import Foundation

public func stansummary(model: String = "bernoulli",
                        arguments: [String] = [],
                        cmdstan: String,
                        verbose: Bool = false) -> (String, String) {

  let dirUrl = casePaths(for: model).results

  let result = stanSummary(dirUrl: dirUrl,
                           modelName: model,
                           cmdstan: cmdstan)
  return result
}
