//
//  AlistTextEmitter.swift
//  Stan
//
//  Slice D of Docs/Stan2AlistCommandPlan.md — renders the reconstructed
//  `[Statement]` list (Slice C) as McElreath `alist()` R source. This is
//  the text that `stan2alist` writes to `Preliminaries/<name>.alist.R`.
//
//  The emitter does NOT aim for byte-identical alist text — the round-trip
//  oracle is at the Stan level (alist → stancode → stan2alist → stancode).
//  It only has to produce alist source that `AlistParser` accepts and that
//  re-classifies to the same model. Two deliberate choices:
//
//    - `bernoulli(p)` is rendered as McElreath's `dbinom(1, p)` idiom.
//    - Distribution arg ORDER is reused verbatim from
//      `DistributionCatalog.args(_:)` — it matches the `rethinking`
//      R-side order for every univariate distribution in v1 scope
//      (dnorm↔normal, dbinom↔binomial, dcauchy↔cauchy, dunif↔uniform, …).
//
//  `c(a, b, c) ~ dnorm(...)` regrouping is intentionally NOT performed:
//  three separate `~` priors lower to the same Stan as one grouped line,
//  so the Stan-level oracle is unaffected (see plan §9).
//
//  T4 (Docs/AlistTransposePlan.md): `.varyingVectorPrior` with a
//  `.multivariateNormalCholesky` distribution is rendered as
//  `name[idx] ~ dmvnorm2(c(names), sigma, L)` by decomposing the stored
//  `diag_pre_multiply(sigma, L)` Cholesky arg and the `[a, b]'` mean arg.
//  This avoids the `'` transpose character in the output and uses a
//  distribution name (`dmvnorm2`) that `AlistParser` / `AlistLowering`
//  can parse back through the T3 `.indexed`-LHS multivariate path.
//

import Foundation

enum AlistTextEmitError: Error, CustomStringConvertible {
  case unsupportedStatement(String)
  case unsupportedLink(String)

  var description: String {
    switch self {
    case .unsupportedStatement(let s):
      return "stan2alist: cannot render statement to alist — \(s)"
    case .unsupportedLink(let s):
      return "stan2alist: link function '\(s)' has no alist representation"
    }
  }
}

enum AlistTextEmitter {

  /// Render the statement list as a full `alist( … )` block, one
  /// statement per line, 2-space indented, comma-separated, trailing
  /// newline.
  static func emit(_ statements: [Statement]) throws -> String {
    let lines = try statements.map(renderStatement)
    let body = lines.map { "  " + $0 }.joined(separator: ",\n")
    return "alist(\n\(body)\n)\n"
  }

  // MARK: - Statements

  private static func renderStatement(_ statement: Statement) throws -> String {
    switch statement {
    case let .likelihood(lhs, dist, _, _):
      return "\(lhs) ~ \(renderDistribution(dist))"
    case let .prior(name, dist, _, _, _, _):
      return "\(name) ~ \(renderDistribution(dist))"
    case let .varyingPrior(name, indexedBy, _, dist, _, _, _, _, _):
      return "\(name)[\(indexedBy)] ~ \(renderDistribution(dist))"
    case let .link(function, lhs, rhs):
      let fn = try linkName(function)
      return "\(fn)(\(lhs)) <- \(rhs.source)"
    case let .deterministic(lhs, rhs):
      return "\(lhs) <- \(rhs.source)"
    case let .generatedQuantity(name, dist):
      return "\(name) <- sim(\(renderDistribution(dist)))"
    case let .vectorPrior(name, _, dist, _, _):
      return "\(name) ~ \(renderDistribution(dist))"
    case let .lkjCorrCholeskyPrior(name, _, eta):
      return "\(name) ~ dlkjcorr(\(DistributionCatalog.arg(eta)))"
    case let .wishartPrior(name, _, nu, V):
      return "\(name) ~ dwishart(\(DistributionCatalog.arg(nu)), \(DistributionCatalog.arg(V)))"
    case let .varyingVectorPrior(name, indexedBy, _, _, dist, _, _):
      // T4: for the Cholesky correlated-effects form, decompose the merged
      // args and emit dmvnorm2(c(names), sigma, L) — parseable by AlistParser
      // without any `'` character (see Docs/AlistTransposePlan.md).
      if case let .multivariateNormalCholesky(mean, chol) = dist,
         let rendered = renderVaryingVectorCholDist(
           name: name, indexedBy: indexedBy,
           meanStr: DistributionCatalog.arg(mean),
           cholStr: DistributionCatalog.arg(chol)) {
        return rendered
      }
      return "\(name)[\(indexedBy)] ~ \(renderDistribution(dist))"
    case let .matrixPrior(name, _, _, dist, _, _):
      return "\(name) ~ \(renderDistribution(dist))"
    case .covMatrixPrior:
      // Declaration-only — no alist sampling idiom. Emit a comment so
      // the file is human-readable; the forward pass re-derives it from
      // the model structure.
      return "# cov_matrix prior (declaration-only — re-derived by stancode)"
    default:
      throw AlistTextEmitError.unsupportedStatement(String(describing: statement))
    }
  }

  private static func linkName(_ function: LinkFunction) throws -> String {
    switch function {
    case .logit: return "logit"
    case .log:   return "log"
    case .invLogit:
      // Stan's `logit(x)` inverse-link has no McElreath alist spelling.
      // Not produced by any v1-scope model; fail loud if it ever is.
      throw AlistTextEmitError.unsupportedLink("invLogit")
    }
  }

  // MARK: - Distributions

  private static func renderDistribution(_ dist: Distribution) -> String {
    // McElreath spells a Bernoulli as a single-trial Binomial.
    if case let .bernoulli(p) = dist {
      return "dbinom(1, \(DistributionCatalog.arg(p)))"
    }
    return "\(DistributionCatalog.mcElreathName(dist))(\(DistributionCatalog.args(dist)))"
  }

  // MARK: - T4: Cholesky varying-vector decomposition

  /// Emit `name[indexedBy] ~ dmvnorm2(c(meanNames), sigma, L)` by
  /// decomposing the stored expression strings:
  ///   meanStr  = `"[a_bar, b_bar]'"` → names `["a_bar", "b_bar"]`
  ///   cholStr  = `"diag_pre_multiply(sigma_ab, L_Omega)"` → (sigma, L)
  ///
  /// Returns nil when either string doesn't match the expected format
  /// (caller falls back to generic rendering; oracle unaffected).
  private static func renderVaryingVectorCholDist(
    name: String,
    indexedBy: String,
    meanStr: String,
    cholStr: String
  ) -> String? {
    // meanStr: "[a_bar, b_bar]'" — strip "[" prefix and "]'" suffix.
    guard meanStr.hasPrefix("["), meanStr.hasSuffix("]'") else { return nil }
    let meanInner = String(meanStr.dropFirst().dropLast(2))
    let names = meanInner.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard !names.isEmpty else { return nil }

    // cholStr: "diag_pre_multiply(sigma, L)" — strip prefix and ")" suffix.
    let dpPrefix = "diag_pre_multiply("
    guard cholStr.hasPrefix(dpPrefix), cholStr.hasSuffix(")") else { return nil }
    let dpInner = String(cholStr.dropFirst(dpPrefix.count).dropLast())
    let dpParts = dpInner.split(separator: ",", maxSplits: 1)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard dpParts.count == 2 else { return nil }
    let sigma = dpParts[0]
    let L = dpParts[1]

    return "\(name)[\(indexedBy)] ~ dmvnorm2(c(\(names.joined(separator: ", "))), \(sigma), \(L))"
  }
}
