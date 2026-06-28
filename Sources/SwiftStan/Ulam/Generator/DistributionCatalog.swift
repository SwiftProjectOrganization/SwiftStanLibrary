//
//  DistributionCatalog.swift
//  Stan
//
//  Render Distribution values to Stan source, report which symbols they
//  reference, classify them as discrete vs continuous (for the
//  `_lpmf`/`_lpdf` choice), and render Truncation suffixes.
//
//  Per-distribution arg-order conversion lives here so the rest of the
//  generator stays distribution-agnostic. Argument orderings happen to
//  match Stan in every Phase 1/3 case we ship — the table below makes
//  that visible.
//

import Foundation

enum DistributionCatalog {

  // MARK: - Sampling form: `dist(args)`

  static func render(_ distribution: Distribution) -> String {
    "\(name(distribution))(\(args(distribution)))"
  }

  /// Stan distribution name with no parens. Used as the base for
  /// `_lpdf`/`_lpmf` emission.
  static func name(_ distribution: Distribution) -> String {
    switch distribution {
    case .normal: return "normal"
    case .bernoulli: return "bernoulli"
    case .binomial: return "binomial"
    case .beta: return "beta"
    case .exponential: return "exponential"
    case .poisson: return "poisson"
    case .gamma: return "gamma"
    case .cauchy: return "cauchy"
    case .lognormal: return "lognormal"
    case .uniform: return "uniform"
    case .studentT: return "student_t"
    case .multivariateNormal: return "multi_normal"
    case .lkjCorrCholesky: return "lkj_corr_cholesky"
    case .multivariateNormalCholesky: return "multi_normal_cholesky"
    case .wishart: return "wishart"
    case .orderedLogistic: return "ordered_logistic"
    case .orderedProbit: return "ordered_probit"
    case .dirichlet: return "dirichlet"
    }
  }

  /// Comma-separated argument list (no parens). Useful for both the
  /// `dist(args)` and `dist_lpdf(y | args)` forms.
  static func args(_ distribution: Distribution) -> String {
    switch distribution {
    case .normal(let mu, let sigma):        return "\(arg(mu)), \(arg(sigma))"
    case .bernoulli(let p):                 return "\(arg(p))"
    case .binomial(let n, let p):           return "\(arg(n)), \(arg(p))"
    case .beta(let a, let b):               return "\(arg(a)), \(arg(b))"
    case .exponential(let r):               return "\(arg(r))"
    case .poisson(let r):                   return "\(arg(r))"
    case .gamma(let shape, let rate):       return "\(arg(shape)), \(arg(rate))"
    case .cauchy(let mu, let sigma):        return "\(arg(mu)), \(arg(sigma))"
    case .lognormal(let mu, let sigma):     return "\(arg(mu)), \(arg(sigma))"
    case .uniform(let lower, let upper):    return "\(arg(lower)), \(arg(upper))"
    case .studentT(let nu, let mu, let s):  return "\(arg(nu)), \(arg(mu)), \(arg(s))"
    case .multivariateNormal(let mu, let s):return "\(arg(mu)), \(arg(s))"
    case .lkjCorrCholesky(let eta):         return "\(arg(eta))"
    case .multivariateNormalCholesky(let mean, let chol):
                                            return "\(arg(mean)), \(arg(chol))"
    case .wishart(let nu, let V):           return "\(arg(nu)), \(arg(V))"
    case .orderedLogistic(let eta, let c),
         .orderedProbit(let eta, let c):    return "\(arg(eta)), \(arg(c))"
    case .dirichlet(let alpha):             return "\(arg(alpha))"
    }
  }

  /// Distributions with integer support — Stan uses `_lpmf` (mass)
  /// rather than `_lpdf` (density) for these.
  static func isDiscrete(_ distribution: Distribution) -> Bool {
    switch distribution {
    case .bernoulli, .binomial, .poisson, .orderedLogistic, .orderedProbit:
      return true
    case .normal, .beta, .exponential, .gamma, .cauchy, .lognormal, .uniform,
         .studentT, .multivariateNormal, .lkjCorrCholesky,
         .multivariateNormalCholesky, .wishart, .dirichlet:
      return false
    }
  }

  /// True when Stan has a scalar-returning `<name>_rng(...)` function for
  /// this distribution — i.e. it is safe to use with `Sim()`.
  ///
  /// Distributions that fail this check either have no `_rng` in Stan
  /// (`lkj_corr_cholesky_rng`, `ordered_probit_rng`) or their `_rng`
  /// returns a non-scalar type (`multi_normal_rng` → vector,
  /// `wishart_rng` → matrix, `dirichlet_rng` → simplex vector).
  static func supportsScalarRng(_ distribution: Distribution) -> Bool {
    switch distribution {
    case .normal, .bernoulli, .binomial, .beta, .exponential, .poisson,
         .gamma, .cauchy, .lognormal, .uniform, .studentT, .orderedLogistic:
      return true
    case .multivariateNormal, .multivariateNormalCholesky, .lkjCorrCholesky,
         .wishart, .dirichlet, .orderedProbit:
      return false
    }
  }

  /// True for distributions whose LHS is a vector / matrix
  /// rather than a scalar. Phase 6 uses this to reject truncation on
  /// the multivariate-normal case (Stan doesn't support `T[...]` on
  /// multivariate distributions). LKJ-Cholesky takes a scalar `eta`
  /// arg but samples a triangular matrix, so it counts as
  /// multivariate for the truncation-rejection purpose.
  static func isMultivariate(_ distribution: Distribution) -> Bool {
    switch distribution {
    case .multivariateNormal, .lkjCorrCholesky, .multivariateNormalCholesky,
         .wishart, .dirichlet:
      return true
    case .normal, .bernoulli, .binomial, .beta, .exponential, .poisson,
         .gamma, .cauchy, .lognormal, .uniform, .studentT,
         .orderedLogistic, .orderedProbit:
      return false
    }
  }

  // MARK: - Symbol extraction

  static func symbolsReferenced(_ distribution: Distribution) -> [String] {
    // Multivariate hierarchical priors (2026-05-31): the args of
    // `multi_normal_cholesky` are compound source-string expressions
    // (`[a_bar, b_bar]'`, `diag_pre_multiply(sigma_ab, L_Omega)`)
    // rather than bare identifiers. Tokenise them into individual
    // identifiers and filter Stan helpers so DataInference's
    // referenced-symbol check sees only the user-named symbols.
    if case .multivariateNormalCholesky(let mean, let chol) = distribution {
      // Both `.symbol` (the historical shape — string-literal init
      // collapses to it) and `.expression` (post-2026-06-08) carry a
      // compound source string here; both tokenise identically.
      let strings = [mean, chol].compactMap { arg -> String? in
        switch arg {
        case .symbol(let s):     return s
        case .expression(let s): return s
        case .literal:           return nil
        }
      }
      return strings.flatMap { tokenizeIdentifiers($0) }
    }
    let parts: [DistributionArg]
    switch distribution {
    case .normal(let a, let b):             parts = [a, b]
    case .bernoulli(let p):                 parts = [p]
    case .binomial(let n, let p):           parts = [n, p]
    case .beta(let a, let b):               parts = [a, b]
    case .exponential(let r):               parts = [r]
    case .poisson(let r):                   parts = [r]
    case .gamma(let a, let b):              parts = [a, b]
    case .cauchy(let a, let b):             parts = [a, b]
    case .lognormal(let a, let b):          parts = [a, b]
    case .uniform(let a, let b):            parts = [a, b]
    case .studentT(let a, let b, let c):    parts = [a, b, c]
    case .multivariateNormal(let a, let b): parts = [a, b]
    case .lkjCorrCholesky(let eta):         parts = [eta]
    case .multivariateNormalCholesky:       parts = [] // handled above
    case .wishart(let nu, let V):           parts = [nu, V]
    case .orderedLogistic(let eta, let c),
         .orderedProbit(let eta, let c):    parts = [eta, c]
    case .dirichlet(let alpha):             parts = [alpha]
    }
    // `.symbol` args contribute their bare identifier directly;
    // `.expression` args are compound source — tokenise to harvest
    // every identifier mention, filtered against the Stan-helper
    // builtin set so DataInference doesn't reject the model as
    // undeclared. Literals contribute nothing.
    return parts.flatMap { arg -> [String] in
      switch arg {
      case .symbol(let s):     return [s]
      case .expression(let s): return tokenizeIdentifiers(s)
      case .literal:           return []
      }
    }
  }

  /// Multivariate hierarchical priors (2026-05-31): identifier
  /// tokeniser for compound distribution-arg source strings. Returns
  /// every `[A-Za-z_][A-Za-z0-9_]*` token that isn't a recognised
  /// Stan helper. Used by `symbolsReferenced` for distributions whose
  /// args are full source-level expressions rather than bare symbols.
  private static func tokenizeIdentifiers(_ source: String) -> [String] {
    let pattern = "[A-Za-z_][A-Za-z0-9_]*"
    let regex = try! NSRegularExpression(pattern: pattern)
    let nsString = source as NSString
    let matches = regex.matches(in: source,
                                range: NSRange(location: 0, length: nsString.length))
    let tokens = matches.map { nsString.substring(with: $0.range) }
    return tokens.filter { !stanHelperBuiltins.contains($0) }
  }

  /// Stan helper functions that may appear inside compound
  /// distribution-arg source strings. Filtered out by
  /// `tokenizeIdentifiers` so DataInference doesn't reject the model
  /// with `undeclaredSymbol(...)`.
  private static let stanHelperBuiltins: Set<String> = [
    "diag_pre_multiply",
    "diag_post_multiply",
    "diag_matrix",
    "rep_vector",
    "cholesky_decompose",
    "quad_form_diag",
    "to_vector",
    "to_row_vector",
    "transpose",
  ]

  static func symbolsReferenced(_ truncation: Truncation) -> [String] {
    var symbols: [String] = []
    if let lower = truncation.lower, case .symbol(let s) = lower {
      symbols.append(s)
    }
    if let upper = truncation.upper, case .symbol(let s) = upper {
      symbols.append(s)
    }
    return symbols
  }

  // MARK: - Truncation suffix

  /// Render ` T[lower, upper]` for the `~` sampling form. Returns an
  /// empty string when neither bound is set. One-sided is supported:
  /// `T[0, ]` (lower only), `T[ , 1]` (upper only).
  static func renderTruncation(_ truncation: Truncation) -> String {
    if truncation.isEmpty { return "" }
    let lower = truncation.lower.map { arg($0) } ?? ""
    let upper = truncation.upper.map { arg($0) } ?? ""
    return " T[\(lower), \(upper)]"
  }

  // MARK: - Bound rendering

  /// Render a Truncation as a parameter-declaration constraint suffix
  /// — e.g. `<lower=0>`, `<upper=1>`, `<lower=0, upper=1>`, or `""`
  /// when no bound is set. Used to constrain parameter declarations
  /// derived from prior truncations.
  static func renderConstraint(_ truncation: Truncation) -> String {
    if truncation.isEmpty { return "" }
    var parts: [String] = []
    if let lower = truncation.lower { parts.append("lower=\(arg(lower))") }
    if let upper = truncation.upper { parts.append("upper=\(arg(upper))") }
    return "<" + parts.joined(separator: ", ") + ">"
  }

  // MARK: - Outcome bounds

  /// Bound constraints emitted on the integer-vector data declaration
  /// for a likelihood's LHS. Continuous-outcome distributions return
  /// `(nil, nil)`; the generator falls back to an unbounded `vector[N]`
  /// declaration in that case.
  struct OutcomeBounds: Hashable, Sendable {
    let lower: String?
    let upper: String?
    var isEmpty: Bool { lower == nil && upper == nil }
  }

  static func outcomeBounds(_ distribution: Distribution) -> OutcomeBounds {
    switch distribution {
    case .bernoulli:
      return OutcomeBounds(lower: "0", upper: "1")
    case .binomial, .poisson:
      // Binomial's upper bound is per-row (`trials[i]`); flat array
      // declarations can't express that. Leave upper unset for Phase 4
      // and revisit if a `transformed data` validation block lands.
      return OutcomeBounds(lower: "0", upper: nil)
    case .orderedLogistic, .orderedProbit:
      // Lower bound is fixed at 1; upper bound is the K cardinality
      // symbol, which the catalog doesn't know about here. DataInference
      // post-fixes `outcomeBoundsByLhs[lhs].upper` after the statement
      // walk by reading the cutpoints arg's K binding from
      // `orderedCutpointParameters`.
      return OutcomeBounds(lower: "1", upper: nil)
    case .normal, .beta, .exponential, .gamma, .cauchy,
         .lognormal, .uniform, .studentT, .multivariateNormal,
         .lkjCorrCholesky, .multivariateNormalCholesky, .wishart,
         .dirichlet:
      return OutcomeBounds(lower: nil, upper: nil)
    }
  }

  // MARK: - Argument rendering

  static func arg(_ a: DistributionArg) -> String {
    switch a {
    case .literal(let x):
      // Whole numbers render without ".0" to match hand-written Stan.
      if x == x.rounded() && abs(x) < 1e15 {
        return String(Int(x))
      } else {
        return String(x)
      }
    case .symbol(let s):
      return s
    case .expression(let s):
      // Verbatim Stan source — same emission as .symbol, but the
      // semantics differ for `symbolsReferenced`: a compound source
      // string gets tokenised into its identifier set there.
      return s
    }
  }
}

// MARK: - Reverse catalog (stan2alist, Slice A)
//
// The `stan2alist` command needs the inverse of `name(_:)` / `args(_:)`:
// given a Stan distribution name and its argument source strings,
// rebuild the canonical `Distribution`, and given a `Distribution`,
// render McElreath's R name (`dnorm`, `dbinom`, …) for the emitted
// `alist()`. Kept here so the forward and reverse tables stay adjacent
// and can't drift — change one, change the other.

extension DistributionCatalog {

  enum ReverseError: Error, CustomStringConvertible {
    /// A Stan distribution name with no in-scope `Distribution` mapping
    /// (e.g. a multivariate, which v1 of stan2alist rejects).
    case unsupportedDistribution(String)
    /// The arg count didn't match the named distribution's arity.
    case arityMismatch(name: String, expected: Int, got: Int)

    var description: String {
      switch self {
      case .unsupportedDistribution(let n):
        return "stan2alist: distribution '\(n)' is not supported (v1 handles univariate distributions only)"
      case .arityMismatch(let n, let expected, let got):
        return "stan2alist: distribution '\(n)' expects \(expected) argument(s), got \(got)"
      }
    }
  }

  /// McElreath's `rethinking` R name for a `Distribution`. Inverse of
  /// `name(_:)` but to the R DSL rather than Stan. The multivariate
  /// rows are best-effort — v1 stan2alist rejects them upstream, so they
  /// exist only to keep the switch exhaustive.
  static func mcElreathName(_ distribution: Distribution) -> String {
    switch distribution {
    case .normal:                     return "dnorm"
    case .bernoulli:                  return "dbinom"   // dbinom(1, p) — trials supplied on emit
    case .binomial:                   return "dbinom"
    case .beta:                       return "dbeta"
    case .exponential:                return "dexp"
    case .poisson:                    return "dpois"
    case .gamma:                      return "dgamma"
    case .cauchy:                     return "dcauchy"
    case .lognormal:                  return "dlnorm"
    case .uniform:                    return "dunif"
    case .studentT:                   return "dstudent"
    case .multivariateNormal:         return "dmvnorm"
    case .lkjCorrCholesky:            return "dlkjcorr"
    case .multivariateNormalCholesky: return "dmvnorm"
    case .wishart:                    return "dwishart"
    case .orderedLogistic:            return "dordlogit"
    case .orderedProbit:              return "dordlogit"
    case .dirichlet:                  return "ddirichlet"
    }
  }

  /// Classify a single Stan argument source string into a
  /// `DistributionArg`. A bare numeric literal becomes `.literal`; a
  /// bare identifier becomes `.symbol`; anything compound (indexing,
  /// arithmetic) becomes `.expression`, mirroring how `arg(_:)` renders
  /// all three identically.
  static func distributionArg(from source: String) -> DistributionArg {
    let trimmed = source.trimmingCharacters(in: .whitespaces)
    if let d = Double(trimmed) {
      return .literal(d)
    }
    if isSimpleIdentifier(trimmed) {
      return .symbol(trimmed)
    }
    return .expression(trimmed)
  }

  private static func isSimpleIdentifier(_ s: String) -> Bool {
    guard let first = s.first, first == "_" || first.isLetter else { return false }
    return s.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  /// Reconstruct a `Distribution` from a Stan distribution name and its
  /// argument source strings. Inverse of `name(_:)` + `args(_:)`. Throws
  /// `ReverseError` for unsupported (multivariate) distributions or an
  /// argument-count mismatch.
  static func distribution(fromStanName name: String,
                           args rawArgs: [String]) throws -> Distribution {
    let a = rawArgs.map(distributionArg(from:))
    func require(_ n: Int) throws {
      guard a.count == n else {
        throw ReverseError.arityMismatch(name: name, expected: n, got: a.count)
      }
    }
    switch name {
    case "normal":      try require(2); return .normal(a[0], a[1])
    case "bernoulli":   try require(1); return .bernoulli(p: a[0])
    case "binomial":    try require(2); return .binomial(n: a[0], p: a[1])
    case "beta":        try require(2); return .beta(a[0], a[1])
    case "exponential": try require(1); return .exponential(a[0])
    case "poisson":     try require(1); return .poisson(a[0])
    case "gamma":       try require(2); return .gamma(a[0], a[1])
    case "cauchy":      try require(2); return .cauchy(a[0], a[1])
    case "lognormal":   try require(2); return .lognormal(a[0], a[1])
    case "uniform":     try require(2); return .uniform(lower: a[0], upper: a[1])
    case "student_t":   try require(3); return .studentT(nu: a[0], mu: a[1], sigma: a[2])
    case "multi_normal":
      try require(2); return .multivariateNormal(mu: a[0], sigma: a[1])
    case "multi_normal_cholesky":
      try require(2); return .multivariateNormalCholesky(mean: a[0], chol: a[1])
    case "lkj_corr_cholesky":
      try require(1); return .lkjCorrCholesky(a[0])
    case "wishart":
      try require(2); return .wishart(nu: a[0], V: a[1])
    default:
      throw ReverseError.unsupportedDistribution(name)
    }
  }
}
