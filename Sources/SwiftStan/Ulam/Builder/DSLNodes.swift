//
//  DSLNodes.swift
//  Stan
//
//  Phase 1 of the ulam port: the four DSL surface types used inside an
//  `UlamModel { ... }` body. Each lowers to one `Statement`.
//

import Foundation

public struct Likelihood: ModelStatement {
  public let lhs: String
  public let distribution: Distribution
  public let truncation: Truncation
  public let useLpdf: Bool

  public init(_ lhs: String,
              _ distribution: Distribution,
              truncation: Truncation = .none,
              useLpdf: Bool = false) {
    self.lhs = lhs
    self.distribution = distribution
    self.truncation = truncation
    self.useLpdf = useLpdf
  }

  public var statement: Statement {
    .likelihood(lhs: lhs, distribution: distribution,
                truncation: truncation, useLpdf: useLpdf)
  }
}

public struct Prior: ModelStatement {
  public let name: String
  public let distribution: Distribution
  public let truncation: Truncation
  public let constraints: Constraints
  public let start: Double?
  public let useLpdf: Bool

  public init(_ name: String,
              _ distribution: Distribution,
              truncation: Truncation = .none,
              constraints: Constraints = .none,
              start: Double? = nil,
              useLpdf: Bool = false) {
    self.name = name
    self.distribution = distribution
    self.truncation = truncation
    self.constraints = constraints
    self.start = start
    self.useLpdf = useLpdf
  }

  public var statement: Statement {
    .prior(name: name, distribution: distribution,
           truncation: truncation, constraints: constraints,
           start: start, useLpdf: useLpdf)
  }
}

/// Phase 6: `mu ~ multi_normal(zero, Sigma)` — plain vector parameter
/// with a multivariate-normal prior. The generator declares
/// `vector[<length>] mu;` in `parameters`. `length` is a cardinality
/// symbol that must be bound by some data column carrying that numeric
/// length (typically the `K` shared with `zero`, `Sigma_prior`,
/// `Sigma_obs` in a bivariate mean-estimation model).
public struct VectorPrior: ModelStatement {
  public let name: String
  public let length: String
  public let distribution: Distribution
  public let truncation: Truncation
  public let useLpdf: Bool

  public init(_ name: String,
              length: String,
              _ distribution: Distribution,
              truncation: Truncation = .none,
              useLpdf: Bool = false) {
    self.name = name
    self.length = length
    self.distribution = distribution
    self.truncation = truncation
    self.useLpdf = useLpdf
  }

  public var statement: Statement {
    .vectorPrior(name: name,
                 length: length,
                 distribution: distribution,
                 truncation: truncation,
                 useLpdf: useLpdf)
  }
}

/// Phase 5: `a[group] ~ normal(a_bar, sigma_a)` — varying-intercept
/// (or varying-coefficient) prior. The generator declares `a` as
/// `vector[N_group]` and `group` as a bounded integer index column.
/// Pass `countSymbol:` to override the auto-derived `N_<indexedBy>`
/// cardinality variable name (e.g. `countSymbol: "K"` to get
/// `vector[K] a;` instead of `vector[N_group] a;`).
///
/// Phase 5.5 Slice E: pass `nonCentered: true` to emit the Matt
/// Trick non-centred parameterisation (`a_raw ~ std_normal();`
/// in `model {}`, `a = a_bar + sigma_a * a_raw;` in
/// `transformed parameters {}`). Only supported with `.normal(...)`
/// and an empty truncation.
public struct VaryingPrior: ModelStatement {
  public let name: String
  public let indexedBy: String
  public let countSymbol: String?
  public let distribution: Distribution
  public let truncation: Truncation
  public let constraints: Constraints
  public let start: Double?
  public let useLpdf: Bool
  public let nonCentered: Bool

  public init(_ name: String,
              indexedBy: String,
              _ distribution: Distribution,
              countSymbol: String? = nil,
              truncation: Truncation = .none,
              constraints: Constraints = .none,
              start: Double? = nil,
              useLpdf: Bool = false,
              nonCentered: Bool = false) {
    self.name = name
    self.indexedBy = indexedBy
    self.countSymbol = countSymbol
    self.distribution = distribution
    self.truncation = truncation
    self.constraints = constraints
    self.start = start
    self.useLpdf = useLpdf
    self.nonCentered = nonCentered
  }

  public var statement: Statement {
    .varyingPrior(name: name,
                  indexedBy: indexedBy,
                  countSymbol: countSymbol,
                  distribution: distribution,
                  truncation: truncation,
                  constraints: constraints,
                  start: start,
                  useLpdf: useLpdf,
                  nonCentered: nonCentered)
  }
}

/// Nested-groupings prior (2026-06-03) — McElreath / brms
/// `a[country, region] ~ dnorm(a_bar, sigma_a)`. One parameter indexed
/// by two integer data columns simultaneously, distinct from two
/// separate `VaryingPrior` summands. v1 supports exactly two grouping
/// dimensions.
///
/// ```swift
/// Deterministic("mu", "a[country, region] + bX*x")
/// NestedVaryingPrior("a", indexedBy: ["country", "region"],
///                    .normal("a_bar", "sigma_a"))
/// Prior("a_bar", .normal(0, 1))
/// Prior("sigma_a", .exponential(1),
///       constraints: Constraints(lower: 0))
/// ```
///
/// Emits `matrix[N_country, N_region] a;` in `parameters{}` and
/// `to_vector(a) ~ normal(a_bar, sigma_a);` in `model{}`. The two
/// index columns are registered with auto-derived cardinality symbols
/// `N_<col>` (override per-position via `countSymbols:`, where any
/// `nil` entry keeps the default).
public struct NestedVaryingPrior: ModelStatement {
  public let name: String
  public let indexedBy: [String]
  public let countSymbols: [String?]
  public let distribution: Distribution
  public let truncation: Truncation
  public let useLpdf: Bool

  public init(_ name: String,
              indexedBy: [String],
              _ distribution: Distribution,
              countSymbols: [String?]? = nil,
              truncation: Truncation = .none,
              useLpdf: Bool = false) {
    self.name = name
    self.indexedBy = indexedBy
    self.countSymbols = countSymbols
      ?? Array(repeating: nil, count: indexedBy.count)
    self.distribution = distribution
    self.truncation = truncation
    self.useLpdf = useLpdf
  }

  public var statement: Statement {
    .nestedVaryingPrior(name: name,
                        indexedBy: indexedBy,
                        countSymbols: countSymbols,
                        distribution: distribution,
                        truncation: truncation,
                        useLpdf: useLpdf)
  }
}

/// SUR Slice A (2026-05-30): `matrix[<rows>, <cols>] <name>;` parameter.
/// The generator declares the matrix in `parameters {}` and emits an
/// iid prior over every entry via `to_vector(<name>) ~ <dist>(args);`
/// — the idiomatic Stan way to put one prior on a whole matrix.
///
/// Used as the per-outcome coefficient matrix β in Seemingly Unrelated
/// Regressions:
///
/// ```swift
/// MatrixPrior("beta", rows: "K", cols: "J", .normal(0, 1))
/// ```
///
/// Both `rows` and `cols` are cardinality symbols (strings) — they
/// must be bound by either a scalar-int data column carrying that
/// name (`"K": .scalarInt(2)`) or a matrix data column whose shape
/// supplies the value.
public struct MatrixPrior: ModelStatement {
  public let name: String
  public let rows: String
  public let cols: String
  public let distribution: Distribution
  public let truncation: Truncation
  public let useLpdf: Bool

  public init(_ name: String,
              rows: String,
              cols: String,
              _ distribution: Distribution,
              truncation: Truncation = .none,
              useLpdf: Bool = false) {
    self.name = name
    self.rows = rows
    self.cols = cols
    self.distribution = distribution
    self.truncation = truncation
    self.useLpdf = useLpdf
  }

  public var statement: Statement {
    .matrixPrior(name: name,
                 rows: rows,
                 cols: cols,
                 distribution: distribution,
                 truncation: truncation,
                 useLpdf: useLpdf)
  }
}

/// SUR Slice B (2026-05-30): `cov_matrix[<dim>] <name>;` parameter.
/// v1 emits no explicit prior — Stan's positive-definite constraint
/// gives the sampler a workable default. Used as the row-level error
/// covariance Σ in SUR models.
///
/// ```swift
/// CovMatrixPrior("Sigma", dim: "J")
/// ```
public struct CovMatrixPrior: ModelStatement {
  public let name: String
  public let dim: String

  public init(_ name: String, dim: String) {
    self.name = name
    self.dim = dim
  }

  public var statement: Statement {
    .covMatrixPrior(name: name, dim: dim)
  }
}

/// Multivariate hierarchical priors Slice A (2026-05-31):
/// `cholesky_factor_corr[<dim>] <name>;` parameter with an LKJ-Cholesky
/// prior on the implied correlation matrix:
///
/// ```swift
/// LKJCorrCholeskyPrior("L_Omega", dim: "J", eta: 2)
/// ```
///
/// Emits the parameter declaration plus
/// `<name> ~ lkj_corr_cholesky(<eta>);` in the model block. `dim` is a
/// cardinality symbol the user binds to a scalar-int data column.
public struct LKJCorrCholeskyPrior: ModelStatement {
  public let name: String
  public let dim: String
  public let eta: DistributionArg

  public init(_ name: String, dim: String, eta: DistributionArg) {
    self.name = name
    self.dim = dim
    self.eta = eta
  }

  public var statement: Statement {
    .lkjCorrCholeskyPrior(name: name, dim: dim, eta: eta)
  }
}

/// Wishart prior on a `cov_matrix[<dim>]` parameter:
///
/// ```swift
/// WishartPrior("Omega", dim: "K", nu: "nu", V: "V_scale")
/// ```
///
/// Declares `cov_matrix[K] Omega;` in the parameters block and emits
/// `Omega ~ wishart(nu, V_scale);` in the model block. `dim` is a
/// cardinality symbol bound to a scalar-int data column; `V` is a symbol
/// referencing a `cov_matrix`-typed data column (the scale matrix).
public struct WishartPrior: ModelStatement {
  public let name: String
  public let dim: String
  public let nu: DistributionArg
  public let V: DistributionArg

  public init(_ name: String, dim: String,
              nu: DistributionArg, V: DistributionArg) {
    self.name = name
    self.dim = dim
    self.nu = nu
    self.V = V
  }

  public var statement: Statement {
    .wishartPrior(name: name, dim: dim, nu: nu, V: V)
  }
}

/// Multivariate hierarchical priors Slice C (2026-05-31):
/// `array[N_<indexedBy>] vector[<length>] <name>;` — vector-valued
/// varying effects with a multivariate prior over the per-group vector:
///
/// ```swift
/// VaryingVectorPrior(
///   "ab", indexedBy: "cafe", length: "J",
///   .multivariateNormalCholesky("[a_bar, b_bar]'",
///                               "diag_pre_multiply(sigma_ab, L_Omega)")
/// )
/// ```
///
/// `indexedBy` is the group-id data column (same role as in
/// `VaryingPrior`); `length` is the inner-vector cardinality (typically
/// the same one used by the companion `LKJCorrCholeskyPrior`).
/// `countSymbol`, when non-nil, overrides the auto-derived `N_<col>`
/// outer cardinality.
public struct VaryingVectorPrior: ModelStatement {
  public let name: String
  public let indexedBy: String
  public let length: String
  public let countSymbol: String?
  public let distribution: Distribution
  public let truncation: Truncation
  public let useLpdf: Bool

  public init(_ name: String,
              indexedBy: String,
              length: String,
              _ distribution: Distribution,
              countSymbol: String? = nil,
              truncation: Truncation = .none,
              useLpdf: Bool = false) {
    self.name = name
    self.indexedBy = indexedBy
    self.length = length
    self.countSymbol = countSymbol
    self.distribution = distribution
    self.truncation = truncation
    self.useLpdf = useLpdf
  }

  public var statement: Statement {
    .varyingVectorPrior(name: name,
                        indexedBy: indexedBy,
                        length: length,
                        countSymbol: countSymbol,
                        distribution: distribution,
                        truncation: truncation,
                        useLpdf: useLpdf)
  }
}

/// Simplex parameter declaration (2026-06-02). Declares
/// `simplex[<length>] <name>;` in the parameters block. Pair with a
/// regular `Prior(<name>, .dirichlet(<alpha>))` for the iid prior:
///
/// ```swift
/// SimplexPrior("delta", length: "K_edu")
/// Prior("delta", .dirichlet("alpha"))
/// ```
///
/// `length` is a cardinality symbol typically anchored by the
/// Dirichlet's `alpha` vector (a `.realVector` of length K_edu) via
/// the existing Phase-6 path.
public struct SimplexPrior: ModelStatement {
  public let name: String
  public let length: String

  public init(_ name: String, length: String) {
    self.name = name
    self.length = length
  }

  public var statement: Statement {
    .simplexPrior(name: name, length: length)
  }
}

/// Monotonic ordinal-predictor effect (2026-06-02). McElreath Chapter
/// 12 / brms `mo()`-style monotonic effect of an ordinal predictor on
/// a linear predictor:
///
/// ```swift
/// Deterministic("mu", "a + bX*x")
/// MonotonicEffect("delta", scale: "bE", predictor: "edu",
///                 levels: "K_edu", targetLhs: "mu")
/// SimplexPrior("delta", length: "K_edu")
/// Prior("delta", .dirichlet("alpha"))
/// ```
///
/// The node consumes the matching `Deterministic`/`Link` whose LHS is
/// `targetLhs` and emits a single combined per-row for-loop that
/// augments the base RHS with `<scale> * sum(<name>[1:<predictor>[i]])`.
/// `levels` is the simplex length (= number of ordinal levels in
/// `predictor`; values must fall in `1..levels`).
public struct MonotonicEffect: ModelStatement {
  public let name: String
  public let scale: String
  public let predictor: String
  public let levels: String
  public let targetLhs: String

  public init(_ name: String,
              scale: String,
              predictor: String,
              levels: String,
              targetLhs: String) {
    self.name = name
    self.scale = scale
    self.predictor = predictor
    self.levels = levels
    self.targetLhs = targetLhs
  }

  public var statement: Statement {
    .monotonicEffect(name: name,
                     scale: scale,
                     predictor: predictor,
                     levels: levels,
                     targetLhs: targetLhs)
  }
}

/// Ordered logit / probit cutpoints (2026-06-02) — McElreath Chapter 12
/// "Monsters and Mixtures". Declares an `ordered[<K>-1] <name>;`
/// parameter for use as the `cutpoints` arg of an `.orderedLogistic`
/// or `.orderedProbit` likelihood:
///
/// ```swift
/// Likelihood("R", .orderedLogistic("phi", "cutpoints"))
/// OrderedCutpoints("cutpoints", K: "K")
/// Prior("cutpoints", .normal(0, 1.5))
/// ```
///
/// `K` is a cardinality symbol the user binds in data
/// (`"K": .scalarInt(7)`). The iid prior on the K-1 cutpoint values is
/// supplied separately as a regular `Prior` over the same name — Stan
/// vectorises the scalar normal across the ordered vector entries
/// automatically.
public struct OrderedCutpoints: ModelStatement {
  public let name: String
  public let K: String

  public init(_ name: String, K: String) {
    self.name = name
    self.K = K
  }

  public var statement: Statement {
    .orderedCutpointsPrior(name: name, K: K)
  }
}

/// Gaussian process prior (2026-06-01) — McElreath Chapter 14 oceanic
/// tools shape. Declares an N-length latent vector with a
/// squared-exponential GP prior keyed on a precomputed `distanceMatrix`
/// data column (must be `matrix[N, N]`). v1 ships the squared-exponential
/// (`cov_GPL2`) kernel only; cardinality is hard-coded to `N` (one
/// observation per group — McElreath's oceanic case). The user supplies
/// scalar priors on the hyperparameters separately:
///
/// ```swift
/// GaussianProcessPrior("g", indexedBy: "society",
///                      distanceMatrix: "Dmat",
///                      etasq: "etasq", rhosq: "rhosq")
/// Prior("etasq", .exponential(2), truncation: Truncation(lower: 0))
/// Prior("rhosq", .exponential(0.5), truncation: Truncation(lower: 0))
/// ```
///
/// Emits the non-centred form internally: declares `vector[N] <name>_z;`
/// in `parameters`, gives it a `std_normal()` prior, declares
/// `vector[N] <name>;` in `transformed parameters`, builds the kernel
/// matrix with the diagonal jitter, and assigns
/// `<name> = cholesky_decompose(K) * <name>_z;`.
public struct GaussianProcessPrior: ModelStatement {
  public let name: String
  public let indexedBy: String
  public let distanceMatrix: String
  public let etasq: DistributionArg
  public let rhosq: DistributionArg
  public let jitter: Double

  public init(_ name: String,
              indexedBy: String,
              distanceMatrix: String,
              etasq: DistributionArg,
              rhosq: DistributionArg,
              jitter: Double = 0.01) {
    self.name = name
    self.indexedBy = indexedBy
    self.distanceMatrix = distanceMatrix
    self.etasq = etasq
    self.rhosq = rhosq
    self.jitter = jitter
  }

  public var statement: Statement {
    .gaussianProcessPrior(name: name,
                          indexedBy: indexedBy,
                          distanceMatrix: distanceMatrix,
                          etasq: etasq,
                          rhosq: rhosq,
                          jitter: jitter)
  }
}

/// User-supplied NUTS warmup initial values (2026-06-02). Use when
/// cmdstan's default U(-2, 2) unconstrained init range is too far from
/// the posterior — typically McElreath-style models with large
/// location priors (`mu ~ Normal(178, 20)`):
///
/// ```swift
/// Likelihood("height", .normal("mu", "sigma"))
/// Prior("mu", .normal(178, 20))
/// Prior("sigma", .uniform(0, 50))
/// Inits(["mu": 178, "sigma": 25])
/// ```
///
/// The pipeline writes `Results/<name>.init.json` and cmdstan
/// auto-picks it up via the `init=<path>` flag. v1 supports scalar
/// Double inits only; vector / array inits are deferred.
public struct Inits: ModelStatement {
  public let values: [String: Double]

  public init(_ values: [String: Double]) {
    self.values = values
  }

  public var statement: Statement {
    .inits(values: values)
  }
}

/// Posterior-predictive draw in the `generated quantities` block.
/// Mirrors `Likelihood` in form but emits
/// `<type>[N] <name> = <dist>_rng(args);` rather than a sampling statement.
/// Continuous distributions produce `vector[N]`; discrete ones produce
/// `array[N] int`. The distribution must reference only parameters and
/// observed data — not model-block locals (Link/Deterministic LHSes):
///
/// ```swift
/// Likelihood("log_radon", .normal("alpha + beta*floor", "sigma"))
/// Prior("alpha", .normal(0, 10))
/// Prior("beta", .normal(0, 10))
/// Prior("sigma", .normal(0, 1), truncation: Truncation(lower: 0))
/// Sim("y_rep", .normal("alpha + beta*floor", "sigma"))
/// ```
///
/// Emits:
///
/// ```stan
/// generated quantities {
///   array[N] real y_rep = normal_rng(alpha + beta*floor, sigma);
/// }
/// ```
public struct Sim: ModelStatement {
  public let name: String
  public let distribution: Distribution

  public init(_ name: String, _ distribution: Distribution) {
    self.name = name
    self.distribution = distribution
  }

  public var statement: Statement {
    .generatedQuantity(name: name, distribution: distribution)
  }
}

public struct Link: ModelStatement {
  public let function: LinkFunction
  public let lhs: String
  public let rhs: Expression

  public init(_ function: LinkFunction, lhs: String, rhs: Expression) {
    self.function = function
    self.lhs = lhs
    self.rhs = rhs
  }

  public var statement: Statement {
    .link(function: function, lhs: lhs, rhs: rhs)
  }
}

public struct Deterministic: ModelStatement {
  public let lhs: String
  public let rhs: Expression

  public init(_ lhs: String, _ rhs: Expression) {
    self.lhs = lhs
    self.rhs = rhs
  }

  public var statement: Statement {
    .deterministic(lhs: lhs, rhs: rhs)
  }
}
