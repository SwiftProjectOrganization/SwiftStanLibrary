//
//  Sample.swift
//
//
//  Created by Robert Goedman on 11/17/25.
//

import Foundation

public func sample(model: String,
                   arguments: [String],
                   cmdstan: String,
                   verbose: Bool = false,
                   nosummary: Bool = false,
                   install: Bool = false) -> (String, String) {

  // 2026-06-02: merge defaults per-key instead of dropping the whole
  // defaults block whenever the user supplies any argument. Previously
  // a single override like `num_warmup=2000` silently lost the
  // `num_chains=4` and `num_samples=1000` defaults — surprising and
  // hard to debug.
  var args: [String] = arguments
  let defaults: [(key: String, value: String)] = [
    ("num_chains", "4"),
    ("num_samples", "1000"),
    ("num_threads", "6")
  ]
  for (key, value) in defaults
  where !args.contains(where: { $0.hasPrefix("\(key)=") }) {
    args.append("\(key)=\(value)")
  }

    _ = FileManager.default
  let paths = casePaths(for: model)
  let dirUrl = paths.results

  do {
    try ensureCaseDirectories(paths, verbose: verbose)
  } catch {
    return ("", "Could not create case directories for \(model): \(error.localizedDescription)")
  }

  var result = ("", "")

  if install {
    print("Installing bernoulli.data.json demo file as \(model).data.json")
    result = createDotJsonDataFile(model: model)
  }

  if result.1 == "" {
    result = stanSample(dirUrl: dirUrl,
                        modelName: model,
                        arguments: args,
                        cmdstan: cmdstan,
                        verbose: verbose)
    printResult(result)
  } else {
    return result // Creation of .json data file failed
  }

  if result.1 == "" {
    result = getSampleResult(dirUrl: dirUrl,
                             modelName: model)
    if verbose {
      printResult(result)
    }
  } else {
    return result // stanSample failed
  }

  if !nosummary {
    if result.1 == "" {
      let result = stanSummary(dirUrl: dirUrl,
                               modelName: model,
                               cmdstan: cmdstan)
      if verbose {
        printResult(result)
      }
    } else {
      if !verbose {
        printResult(result)
      }
      return result // getSampleResults failed
    }
  }

  if !nosummary {
    if result.1 == "" {
      result = extractStanSummary(dirUrl: dirUrl,
                                  modelName: model)
      if verbose {
        printResult(result)
      }

    } else {
      return result // stanSummary failed
    }
  }

  return result
}
