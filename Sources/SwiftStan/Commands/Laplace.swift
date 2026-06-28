//
//  Laplace.swift
//  Stan
//
//  Slice β of Docs/Planning docs/LaplaceCommandPlan.md.
//
//  cmdstan's `laplace` subcommand requires an explicit `mode=<file>`
//  pointing at a previously-computed posterior mode (it does *not*
//  auto-optimise — verified against cmdstan 2.38). So this
//  orchestrator:
//
//   1. If the user passed `mode=…` in `arguments`, use it verbatim.
//   2. Otherwise, ensure `Results/<name>_optimize.csv` exists *and*
//      still carries cmdstan's `#`-prefixed header (the mode= reader
//      uses those header lines to recognise the file — without them
//      cmdstan rejects it as "CSV file is not output from Stan
//      optimization"). If either condition is missing, run
//      `stanOptimize` to (re-)write a fresh raw file. Inject
//      `mode=<dirUrl>/<name>_optimize.csv` into the laplace argv.
//   3. Shell to cmdstan via `stanLaplace`.
//   4. Post-process the raw CSV via `getLaplaceResult`.
//
//  The raw `_optimize.csv` survives the post-processing step
//  (`getOptimizeResult` now writes its cleaned output to a sibling
//  `<name>.optimize.csv` instead of overwriting in place), so the
//  skip-if-valid check is safe and avoids a redundant optimize call
//  on every laplace invocation.
//

import Foundation

public func laplace(model: String = "bernoulli",
                    arguments: [String] = [],
                    cmdstan: String,
                    verbose: Bool = false) -> (String, String) {

  let dirUrl = casePaths(for: model).results

  var laplaceArgs: [String] = ["laplace"]
  let hasUserMode = arguments.contains { $0.hasPrefix("mode=") }
  if !hasUserMode {
    let optimizeOut = dirUrl.appendingPathComponent("\(model)_optimize.csv")
    if !looksLikeRawOptimizeOutput(optimizeOut) {
      if verbose {
        print("laplace: \(model)_optimize.csv missing or has no cmdstan header; running optimize to refresh.")
      }
      let optResult = stanOptimize(dirUrl: dirUrl,
                                   modelName: model,
                                   arguments: [],
                                   cmdstan: cmdstan,
                                   verbose: verbose)
      if optResult.1 != "" {
        printResult(optResult)
        return ("", "laplace: optimize prerequisite failed: \(optResult.1)")
      }
    } else if verbose {
      print("laplace: reusing existing raw \(model)_optimize.csv as mode source.")
    }
    laplaceArgs.append("mode=" + optimizeOut.path)
  }
  laplaceArgs.append(contentsOf: arguments)

  var result = stanLaplace(dirUrl: dirUrl,
                           modelName: model,
                           arguments: laplaceArgs,
                           cmdstan: cmdstan,
                           verbose: verbose)

  printResult(result)

  if result.1 == "" {
    result = getLaplaceResult(dirUrl: dirUrl, modelName: model)
    if verbose {
      printResult(result)
    }
  } else {
    printResult(result)
    return result
  }

  return result
}

/// A cmdstan-produced `_optimize.csv` starts with `# stan_version_major = …`.
/// Cleaned files don't. Used to decide whether `<name>_optimize.csv` is
/// reusable as a `mode=` source or needs to be re-generated.
private func looksLikeRawOptimizeOutput(_ url: URL) -> Bool {
  guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
        let first = data.first else {
    return false
  }
  return first == UInt8(ascii: "#")
}
