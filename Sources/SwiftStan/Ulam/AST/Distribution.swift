//
//  Distribution.swift
//  Stan
//
//  Phase 1 introduced the small Bernoulli/Beta/Normal/Binomial/Exponential
//  set used for the canonical Statistical Rethinking opening example.
//  Phase 3 widens this to Poisson, Gamma, Cauchy, LogNormal, Uniform,
//  and Student-t.
//

import Foundation

/// A scalar argument to a distribution — either a numeric literal or a
/// reference to a named symbol (parameter or data value).
public enum DistributionArg: Hashable, Sendable {
  case literal(Double)
  case symbol(String)
  /// Verbatim Stan source for a compound expression — e.g.
  /// `.normal(.expression("alpha[county] + beta*x"), "sigma")`.
  /// Renders identically to `.symbol` (emitted as-is by
  /// `DistributionCatalog.arg(_:)`), but `symbolsReferenced(_:)`
  /// tokenises the source to harvest the embedded identifiers
  /// (`alpha`, `county`, `beta`, `x`) so they end up in the
  /// referenced-symbol set the data-block emitter walks.
  /// 2026-06-08, TestResults §2.
  case expression(String)
}

extension DistributionArg: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    self = .literal(Double(value))
  }
}

extension DistributionArg: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self = .literal(value)
  }
}

extension DistributionArg: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .symbol(value)
  }
}

public enum Distribution: Hashable, Sendable {
  // Phase 1
  case normal(_ mu: DistributionArg, _ sigma: DistributionArg)
  case bernoulli(p: DistributionArg)
  case binomial(n: DistributionArg, p: DistributionArg)
  case beta(_ alpha: DistributionArg, _ beta: DistributionArg)
  case exponential(_ rate: DistributionArg)
  // Phase 3
  case poisson(_ rate: DistributionArg)
  case gamma(_ shape: DistributionArg, _ rate: DistributionArg)
  case cauchy(_ mu: DistributionArg, _ sigma: DistributionArg)
  case lognormal(_ mu: DistributionArg, _ sigma: DistributionArg)
  case uniform(lower: DistributionArg, upper: DistributionArg)
  case studentT(nu: DistributionArg, mu: DistributionArg, sigma: DistributionArg)
  // Phase 6 — multivariate normal. `mu` is a vector-typed symbol;
  // `sigma` is a matrix-typed symbol (cov_matrix). The DistributionArg
  // stays scalar-typed in v1 — the symbols are emitted verbatim and
  // Stan catches type mismatches at compile time.
  case multivariateNormal(mu: DistributionArg, sigma: DistributionArg)
  // Multivariate hierarchical priors (2026-05-31) — LKJ prior on a
  // Cholesky-factored correlation matrix. Used as the prior on a
  // `cholesky_factor_corr[J]` parameter. The single `eta` arg shapes
  // the LKJ density (η=1 → uniform over correlation matrices, η>1
  // concentrates around the identity).
  case lkjCorrCholesky(_ eta: DistributionArg)
  // Multivariate hierarchical priors (2026-05-31) — multivariate
  // normal taking a Cholesky factor of the covariance directly. The
  // mean arg is typically a row-vector expression
  // (`[a_bar, b_bar]'`); the chol arg is typically a
  // `diag_pre_multiply(sigma, L_Omega)` call. Both render into Stan
  // source verbatim; identifier symbols inside the source strings are
  // discovered by tokenisation in DistributionCatalog so the
  // generator doesn't flag them as undeclared.
  case multivariateNormalCholesky(mean: DistributionArg, chol: DistributionArg)
  // Wishart prior on a covariance matrix (`cov_matrix[dim]`).
  // `nu` is degrees of freedom (must be > dim - 1); `V` is the
  // scale matrix symbol (typically a `cov_matrix`-typed data column).
  case wishart(nu: DistributionArg, V: DistributionArg)
  // Ordered logit (2026-06-02) — discrete outcome 1..K modelled via a
  // latent linear predictor `eta` and K-1 ordered cutpoints. `cutpoints`
  // must be a symbol naming an `ordered[K-1]`-typed parameter declared
  // by a companion `OrderedCutpoints` statement.
  case orderedLogistic(eta: DistributionArg, cutpoints: DistributionArg)
  // Ordered probit — same structure, probit link instead of logit.
  case orderedProbit(eta: DistributionArg, cutpoints: DistributionArg)
  // Dirichlet (2026-06-02) — multivariate prior on a simplex parameter.
  // `alpha` is a vector-typed symbol giving the per-entry concentration
  // (uniform `rep_vector(2, K)` is a common weakly-informative choice).
  // The receiving parameter must be declared as `simplex[K]` via a
  // companion `SimplexPrior` node.
  case dirichlet(_ alpha: DistributionArg)
}
