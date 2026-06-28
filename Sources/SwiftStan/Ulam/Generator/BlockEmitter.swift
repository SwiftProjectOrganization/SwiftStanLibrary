//
//  BlockEmitter.swift
//  Stan
//
//  Emit Stan source for the `data`, `parameters`, and `model` blocks
//  from an InferredModel.
//
//  Phase 4 additions:
//  - Outcome data declarations carry per-distribution bounds (e.g.
//    `array[N] int<lower=0, upper=1> y;` for a Bernoulli outcome).
//  - Parameter declarations carry constraints inferred from any
//    truncation on the symbol's prior (e.g. `real<lower=0> sigma;` when
//    `Prior("sigma", .normal(0,1), truncation: Truncation(lower: 0))`).
//  - `vectorisationStrategy(for:)` predicate decides per-statement
//    whether the emitter takes the vectorised path (everything
//    Phase 1–4 generates) or the loop path (reserved for Phase 5 —
//    currently routes to BlockEmitterError.loopEmissionRequired since
//    no Phase-4 statement triggers indexed RHS expressions).
//
//  Phase 5.5 Slice B: `vectorisationStrategy(for:)` now walks the
//  parsed `ExpressionNode` instead of regex-matching the raw RHS
//  string. Behaviour is identical for every shipping demo (12/12
//  golden tests byte-identical) but the new path also catches
//  whitespace-disguised indexing (`a [ group ]`) and surfaces a
//  proper `BlockEmitterError.malformedExpression` for unparseable
//  RHS instead of silently treating it as vectorisable.
//

import Foundation

enum BlockEmitter {
  static func dataBlock(_ inferred: InferredModel) -> String {
    var lines: [String] = []
    lines.append("data {")
    if inferred.N != nil {
      lines.append("  int<lower=1> N;")
    }
    // Phase 5: cardinality declarations for index columns must come
    // before any data column that references them. Sorted by symbol for
    // stable output. `N` itself is already emitted above, so filter it
    // out — GP-style group indices that key on `N` directly (oceanic
    // tools: one observation per island) would otherwise duplicate it.
    let countSymbols = Set(inferred.indexColumns.values)
      .subtracting(["N"])
      .sorted()
    for symbol in countSymbols {
      lines.append("  int<lower=1> \(symbol);")
    }
    // Phase 6: cardinality declarations for VectorPrior-introduced
    // symbols. Sorted; emitted before any Phase-6-shaped column.
    for symbol in inferred.phaseSixCardinalitySymbols.keys.sorted() {
      lines.append("  int<lower=1> \(symbol);")
    }
    for (name, col) in inferred.dataVectors {
      switch col {
      case .real:
        lines.append("  vector[N] \(name);")
      case .integer:
        if let countSymbol = inferred.indexColumns[name] {
          // Phase 5: tightened bounds on an index column.
          lines.append("  array[N] int<lower=1, upper=\(countSymbol)> \(name);")
        } else if inferred.promotedIntColumns.contains(name) {
          // Phase 5.5 Slice C: column appears in real-typed arithmetic,
          // so emit as `vector[N]` rather than `array[N] int`.
          lines.append("  vector[N] \(name);")
        } else {
          let bounds = renderBounds(inferred.outcomeBoundsByLhs[name])
          lines.append("  array[N] int\(bounds) \(name);")
        }
      case .realArrayVector:
        // Phase 6: `array[N] vector[<symbol>] <name>;`. The cardinality
        // symbol is bound in DataInference.
        if let symbol = inferred.phaseSixColumnSymbols[name] {
          lines.append("  array[N] vector[\(symbol)] \(name);")
        }
      case .realMatrix(_, let cols, _):
        // SUR Slice C: `matrix[N, <cols-literal>] <name>;`. The
        // column dimension is emitted as a literal — model-block
        // references that use a `K`/`J` cardinality symbol pick up
        // the matching scalar-int data the user supplied.
        // GP override: distance matrices flagged by a
        // GaussianProcessPrior emit as `matrix[N, N]` since they're
        // square by construction.
        if inferred.squareMatrixColumns.contains(name) {
          lines.append("  matrix[N, N] \(name);")
        } else {
          lines.append("  matrix[N, \(cols)] \(name);")
        }
      case .scalarReal, .scalarInt, .realVector, .realCovMatrix:
        break // unreachable here; partitioned out by DataInference
      }
    }
    for (name, col) in inferred.dataScalars {
      switch col {
      case .scalarReal:
        lines.append("  real \(name);")
      case .scalarInt:
        lines.append("  int \(name);")
      case .realVector:
        if let symbol = inferred.phaseSixColumnSymbols[name] {
          lines.append("  vector[\(symbol)] \(name);")
        }
      case .realCovMatrix:
        if let symbol = inferred.phaseSixColumnSymbols[name] {
          lines.append("  cov_matrix[\(symbol)] \(name);")
        } else if let dim = inferred.wishartScaleColumns[name] {
          // Wishart scale matrix: bound by the companion WishartPrior's
          // dim symbol rather than a Phase-6 cardinality symbol.
          lines.append("  cov_matrix[\(dim)] \(name);")
        }
      case .real, .integer, .realArrayVector, .realMatrix:
        break // unreachable here; partitioned by isVector
      }
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  static func parametersBlock(_ inferred: InferredModel) -> String {
    var lines: [String] = []
    lines.append("parameters {")
    for name in inferred.parameters {
      let constraint = inferred.parameterConstraints[name] ?? ""
      if let countSymbol = inferred.vectorParameters[name] {
        // Phase 5: vector-typed parameter. Stan syntax for a constrained
        // vector is `vector<lower=0>[N] x;`, not `vector[N]<lower=0> x;`,
        // so the constraint suffix attaches to `vector`, not the size.
        lines.append("  vector\(constraint)[\(countSymbol)] \(name);")
      } else if let shape = inferred.matrixParameters[name] {
        // SUR Slice A: matrix-typed parameter. v1 doesn't carry
        // per-entry constraints on matrix declarations; the iid prior
        // emitted by modelBlock (`to_vector(name) ~ dist(args);`) does
        // the analogous job.
        lines.append("  matrix[\(shape.rows), \(shape.cols)] \(name);")
      } else if let dim = inferred.covMatrixParameters[name] {
        // SUR Slice B: cov_matrix parameter. Stan's declaration
        // constraint is positive-definite; no extra `<lower=...>`
        // syntax applies.
        lines.append("  cov_matrix[\(dim)] \(name);")
      } else if let dim = inferred.cholFactorParameters[name] {
        // Multivariate hierarchical priors Slice A: triangular Cholesky
        // factor of a correlation matrix. Stan's constraint is built
        // into the declaration keyword.
        lines.append("  cholesky_factor_corr[\(dim)] \(name);")
      } else if let shape = inferred.varyingVectorParameters[name] {
        // Multivariate hierarchical priors Slice C: vector-valued
        // varying effect — outer array indexed by the group count,
        // inner vector of length `<length>`.
        lines.append("  array[\(shape.outer)] vector[\(shape.length)] \(name);")
      } else if let dim = inferred.orderedCutpointParameters[name] {
        // Ordered logit / probit (2026-06-02): `ordered[<K>-1] <name>;`.
        // The K-1 size form renders Stan's bracketed expression form
        // verbatim — Stan's parser accepts the literal subtraction.
        lines.append("  ordered[\(dim)-1] \(name);")
      } else if let len = inferred.simplexParameters[name] {
        // Monotonic effects (2026-06-02): `simplex[<length>] <name>;`.
        lines.append("  simplex[\(len)] \(name);")
      } else {
        lines.append("  real\(constraint) \(name);")
      }
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  /// Phase 5.5 Slice E: emit the `transformed parameters {}` block
  /// for any non-centred VaryingPriors. Returns nil when the model
  /// has no non-centred entries — StanCodeGenerator skips the block
  /// entirely in that case so centred models stay byte-identical.
  ///
  /// 2026-06-01 — extended for `GaussianProcessPrior`: each GP entry
  /// adds a `vector[<N>] <name>;` declaration plus a nested block that
  /// builds the squared-exponential kernel matrix, adds the diagonal
  /// jitter, and assigns `<name> = cholesky_decompose(K) * <name>_z;`.
  /// 2026-06-06 (TODO §2): `transformed data {}` block emitting per-row
  /// binomial outcome validation. One `for (i in 1:N)` loop per binomial
  /// likelihood whose trials argument is a vector data column — each
  /// row violating `outcome[i] <= trials[i]` raises a `reject(...)` at
  /// data-load time, surfacing the row index instead of cmdstan's stock
  /// "log probability is -inf" later in sampling. Returns `nil` when no
  /// such checks are needed so models without vector-trials binomials
  /// stay byte-identical to v1 output.
  static func transformedDataBlock(_ inferred: InferredModel) -> String? {
    if inferred.binomialRowChecks.isEmpty { return nil }
    var lines: [String] = ["transformed data {"]
    for check in inferred.binomialRowChecks {
      let outcome = check.outcome
      let trials = check.trials
      lines.append("  for (i in 1:N) {")
      lines.append("    if (\(outcome)[i] > \(trials)[i]) {")
      lines.append("      reject(\"\(outcome)[\", i, \"] = \", \(outcome)[i],")
      lines.append("             \" > \(trials)[\", i, \"] = \", \(trials)[i],")
      lines.append("             \" — binomial outcome must satisfy y[i] <= trials[i]\");")
      lines.append("    }")
      lines.append("  }")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  static func transformedParametersBlock(_ inferred: InferredModel) -> String? {
    if inferred.nonCenteredVarying.isEmpty && inferred.gaussianProcessGP.isEmpty {
      return nil
    }
    var lines: [String] = ["transformed parameters {"]
    // Declarations first, then assignments. Sort each section by name
    // for stable output.
    for name in inferred.nonCenteredVarying.keys.sorted() {
      let spec = inferred.nonCenteredVarying[name]!
      lines.append("  vector[\(spec.countSymbol)] \(name);")
    }
    for name in inferred.gaussianProcessGP.keys.sorted() {
      let spec = inferred.gaussianProcessGP[name]!
      lines.append("  vector[\(spec.countSymbol)] \(name);")
    }
    for name in inferred.nonCenteredVarying.keys.sorted() {
      let spec = inferred.nonCenteredVarying[name]!
      let mu = DistributionCatalog.arg(spec.muArg)
      let sigma = DistributionCatalog.arg(spec.sigmaArg)
      lines.append("  \(name) = \(mu) + \(sigma) * \(spec.rawName);")
    }
    for name in inferred.gaussianProcessGP.keys.sorted() {
      let spec = inferred.gaussianProcessGP[name]!
      let etasq = DistributionCatalog.arg(spec.etasq)
      let rhosq = DistributionCatalog.arg(spec.rhosq)
      let n = spec.countSymbol
      lines.append("  {")
      lines.append("    matrix[\(n), \(n)] K;")
      lines.append("    for (i in 1:\(n)) {")
      lines.append("      for (j in 1:\(n)) {")
      lines.append("        K[i, j] = \(etasq) * exp(-\(rhosq) * square(\(spec.distanceMatrix)[i, j]));")
      lines.append("      }")
      lines.append("      K[i, i] = K[i, i] + \(renderJitter(spec.jitter));")
      lines.append("    }")
      lines.append("    \(name) = cholesky_decompose(K) * \(spec.rawName);")
      lines.append("  }")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  /// Render the GP diagonal-jitter constant. `0.01` should render as
  /// `0.01`, not `0.01000000…`. Whole-number doubles drop the `.0`
  /// suffix only when an integer literal would parse identically in
  /// Stan — Stan accepts both, but the McElreath idiom is the decimal
  /// form (`0.01`).
  private static func renderJitter(_ value: Double) -> String {
    return "\(value)"
  }

  /// Emit the `generated quantities {}` block for posterior-predictive draws.
  /// Returns nil when the model has no `generatedQuantity` statements, keeping
  /// models without a `sim()` line byte-identical to their previous output.
  static func generated_QuantitiesBlock(_ inferred: InferredModel) -> String? {
    if inferred.generated_Quantities.isEmpty { return nil }
    var lines = ["generated quantities {"]
    for gq in inferred.generated_Quantities {
      let rng  = DistributionCatalog.name(gq.distribution) + "_rng"
      let args = DistributionCatalog.args(gq.distribution)
      let decl = DistributionCatalog.isDiscrete(gq.distribution) ? "array[N] int" : "array[N] real"
      lines.append("  \(decl) \(gq.name) = \(rng)(\(args));")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  static func modelBlock(_ inferred: InferredModel,
                         statements: [Statement]) throws -> String {
    var lines: [String] = []
    lines.append("model {")

    // SUR Slices D + E (2026-05-30): detect per-row multivariate
    // outcomes — a `Likelihood("y", .multivariateNormal("mu", "Sigma"))`
    // whose LHS is a matrix data column, paired with a
    // `Deterministic("mu", "x[n]*beta")` that defines the row-level
    // mean. The pair is emitted as a single per-row for-loop and the
    // two original statements are skipped in the main walk.
    let matrixDataColumns: Set<String> = Set(
      inferred.dataVectors.compactMap { (name, col) -> String? in
        if case .realMatrix = col { return name }
        return nil
      }
    )
    let surPlan = detectSurLoops(statements: statements,
                                 inferred: inferred,
                                 matrixDataColumns: matrixDataColumns)

    // Monotonic effects (2026-06-02): pair each MonotonicEffect with its
    // target Link/Deterministic. The detection consumes the original
    // assignment statement so it doesn't emit its plain vectorised form;
    // a single combined per-row for-loop replaces it below.
    let monoPlan = detectMonotonicLoops(statements: statements,
                                        inferred: inferred)

    // Declare derived locals up front — except those promoted into the
    // SUR loop body as a `row_vector[<J>] <name>;` local.
    for name in inferred.derived where !surPlan.localMeanNames.contains(name) {
      lines.append("  vector[N] \(name);")
    }

    // Group output: assignments first, then priors, then likelihoods.
    // Stan doesn't require this ordering but it matches hand-written style.
    var assignments: [String] = []
    var priors: [String] = []
    var likelihoods: [String] = []

    // Slice E: include transformed-parameter (non-centred-original)
    // names so `a[group]` still vectorises when `a` is defined in
    // `transformed parameters` rather than declared in `parameters`.
    let knownVectorParameters = Set(inferred.vectorParameters.keys)
      .union(inferred.nonCenteredVarying.keys)
      .union(inferred.gaussianProcessGP.keys)
    let knownIndexColumns = Set(inferred.indexColumns.keys)
    // Slice D: type-tracking input — which data columns end up as
    // `vector[N]` in the data block (real columns + Slice-C-promoted
    // int columns). Used by `isVectorTyped` and by the loop-body
    // renderer to decide which identifiers need `[i]` subscripting.
    let knownDataVectors = dataVectorNames(inferred)
    // Multivariate hierarchical priors Slice D: vector-of-vectors
    // varying parameters — the LHS allowed for `ab[cafe][k]` access.
    let knownVaryingVectorParameters = Set(inferred.varyingVectorParameters.keys)
    for (statementIndex, statement) in statements.enumerated() {
      // SUR Slices D + E: skip statements consumed by a detected
      // per-row pair — they're emitted together as a for-loop block
      // after the main walk.
      if surPlan.consumedStatements.contains(statementIndex) { continue }
      // Monotonic effects (2026-06-02): skip the consumed
      // Link/Deterministic; its augmented form is emitted as a
      // combined for-loop into the `assignments` bucket below.
      if monoPlan.consumedStatements.contains(statementIndex) { continue }
      switch statement {
      case .link(let function, let lhs, let rhs):
        switch try vectorisationStrategy(for: statement,
                                         knownVectorParameters: knownVectorParameters,
                                         knownIndexColumns: knownIndexColumns,
                                         knownDataVectors: knownDataVectors) {
        case .vectorise:
          assignments.append("  \(lhs) = \(applyInverseLink(function, to: rhs.source));")
        case .loop:
          // Slice D: parse + translate into a `for (i in 1:N)` body.
          let node = try parseRhs(rhs, symbolForError: lhs)
          guard canLoopEmit(node,
                            knownVectorParameters: knownVectorParameters,
                            knownVaryingVectorParameters: knownVaryingVectorParameters) else {
            throw BlockEmitterError.loopEmissionRequired(symbol: lhs)
          }
          let body = renderLoopBody(node,
                                    knownDataVectors: knownDataVectors,
                                    knownIndexColumns: knownIndexColumns,
                                    loopVar: "i")
          assignments.append("  for (i in 1:N) {")
          assignments.append("    \(lhs)[i] = \(applyInverseLink(function, to: body));")
          assignments.append("  }")
        }
        continue
      case .deterministic(let lhs, let rhs):
        switch try vectorisationStrategy(for: statement,
                                         knownVectorParameters: knownVectorParameters,
                                         knownIndexColumns: knownIndexColumns,
                                         knownDataVectors: knownDataVectors) {
        case .vectorise:
          assignments.append("  \(lhs) = \(rhs.source);")
        case .loop:
          let node = try parseRhs(rhs, symbolForError: lhs)
          guard canLoopEmit(node,
                            knownVectorParameters: knownVectorParameters,
                            knownVaryingVectorParameters: knownVaryingVectorParameters) else {
            throw BlockEmitterError.loopEmissionRequired(symbol: lhs)
          }
          let body = renderLoopBody(node,
                                    knownDataVectors: knownDataVectors,
                                    knownIndexColumns: knownIndexColumns,
                                    loopVar: "i")
          assignments.append("  for (i in 1:N) {")
          assignments.append("    \(lhs)[i] = \(body);")
          assignments.append("  }")
        }
        continue
      default:
        break
      }

      switch statement {
      case .link, .deterministic:
        break // handled above
      case .prior(let name, let dist, let trunc, _, _, let useLpdf):
        priors.append(try emitSampling(lhs: name, distribution: dist,
                                       truncation: trunc, useLpdf: useLpdf))
      case .varyingPrior(let name, _, _, let dist, let trunc, _, _, let useLpdf, _):
        // Phase 5.5 Slice E: non-centred VaryingPriors swap the centred
        // sampling line `<name> ~ normal(mu, sigma);` for the standard
        // form `<name>_raw ~ std_normal();`. The mu/sigma multiplication
        // lives in the `transformed parameters` block.
        if let spec = inferred.nonCenteredVarying[name] {
          priors.append("  \(spec.rawName) ~ std_normal();")
        } else {
          // Phase 5: emit as a scalar prior. Stan vectorises the `~`
          // operator over the vector parameter declared by Slice B.
          priors.append(try emitSampling(lhs: name, distribution: dist,
                                         truncation: trunc, useLpdf: useLpdf))
        }
      case .vectorPrior(let name, _, let dist, let trunc, let useLpdf):
        // Phase 6 Slice A: emit as a scalar-shaped sampling line.
        // Stan vectorises `~` over the vector LHS once Slice B
        // declares the parameter as `vector[<length>]`.
        priors.append(try emitSampling(lhs: name, distribution: dist,
                                       truncation: trunc, useLpdf: useLpdf))
      case .matrixPrior(let name, _, _, let dist, let trunc, let useLpdf):
        // SUR Slice A: matrix parameters take an iid prior on every
        // entry via the `to_vector(<name>)` flattening. cmdstan's
        // sampler then treats every cell as a draw from `dist`.
        priors.append(try emitSampling(lhs: "to_vector(\(name))",
                                       distribution: dist,
                                       truncation: trunc,
                                       useLpdf: useLpdf))
      case .nestedVaryingPrior(let name, _, _, let dist, let trunc, let useLpdf):
        // Nested groupings (2026-06-03): iid flat prior over every cell
        // of the `matrix[N_<col1>, N_<col2>]` parameter via the same
        // `to_vector(<name>) ~ <dist>;` idiom as MatrixPrior. The
        // declaration shape lives in `matrixParameters` (set by
        // DataInference), so parametersBlock emits it for free.
        priors.append(try emitSampling(lhs: "to_vector(\(name))",
                                       distribution: dist,
                                       truncation: trunc,
                                       useLpdf: useLpdf))
      case .covMatrixPrior:
        // SUR Slice B: no sampling statement — Stan's `cov_matrix`
        // declaration constraint (positive-definite) is enough to give
        // the sampler a workable starting prior. A future
        // `LKJCovMatrixPrior` would emit the Cholesky decomposition
        // here; v1 keeps the plain form.
        break
      case .lkjCorrCholeskyPrior(let name, _, let eta):
        // Multivariate hierarchical priors Slice A: emit the LKJ
        // sampling line over the triangular Cholesky factor.
        priors.append(try emitSampling(lhs: name,
                                       distribution: .lkjCorrCholesky(eta),
                                       truncation: .none,
                                       useLpdf: false))
      case .wishartPrior(let name, _, let nu, let V):
        // Wishart prior on a cov_matrix parameter.
        priors.append(try emitSampling(lhs: name,
                                       distribution: .wishart(nu: nu, V: V),
                                       truncation: .none,
                                       useLpdf: false))
      case .varyingVectorPrior(let name, _, _, _, let dist, let trunc, let useLpdf):
        // Multivariate hierarchical priors Slice C: emit the scalar
        // sampling line. Stan vectorises `~` over the outer array
        // automatically.
        priors.append(try emitSampling(lhs: name, distribution: dist,
                                       truncation: trunc, useLpdf: useLpdf))
      case .gaussianProcessPrior(let name, _, _, _, _, _):
        // Gaussian process Slice D: the K-construction +
        // cholesky_decompose lives in `transformed parameters`; the
        // model block carries only the standard-normal prior on the
        // raw z-vector.
        if let spec = inferred.gaussianProcessGP[name] {
          priors.append("  \(spec.rawName) ~ std_normal();")
        }
      case .orderedCutpointsPrior:
        // Ordered cutpoints (2026-06-02): declaration-only. The iid
        // prior across the K-1 cutpoint entries is supplied via a
        // separate `Prior(<name>, ...)` statement that Stan vectorises
        // automatically over the ordered vector.
        break
      case .simplexPrior:
        // Monotonic effects (2026-06-02): declaration-only — the user
        // attaches `Prior(<name>, .dirichlet(<alpha>))` separately.
        break
      case .monotonicEffect:
        // Monotonic effects: consumed by the detection pass above —
        // its per-row contribution is folded into a combined for-loop
        // assignment for the matching Link/Deterministic.
        break
      case .inits:
        // NUTS warmup inits (2026-06-02): pure metadata — the
        // pipeline marshals it into `<name>.init.json` rather than
        // emitting any Stan source.
        break
      case .generatedQuantity:
        // Emitted by generated_QuantitiesBlock, not the model block.
        break
      case .likelihood(let lhs, let dist, let trunc, let useLpdf):
        likelihoods.append(try emitSampling(lhs: lhs, distribution: dist,
                                            truncation: trunc, useLpdf: useLpdf))
      }
    }

    // Monotonic effects (2026-06-02): emit each detected combined
    // for-loop in place of the suppressed Link/Deterministic. Inserted
    // into the assignments bucket so derived locals are populated
    // before priors and likelihoods that consume them.
    for loop in monoPlan.loops {
      assignments.append("  for (i in 1:N) {")
      assignments.append("    \(loop.targetLhs)[i] = \(loop.combinedBody);")
      assignments.append("  }")
    }

    lines.append(contentsOf: assignments)
    lines.append(contentsOf: priors)
    lines.append(contentsOf: likelihoods)

    // SUR Slices D + E: emit each per-row pair as a single
    // `for (n in 1:N) { row_vector[J] mu = …; y[n] ~ multi_normal(…); }`
    // block at the bottom of the model block.
    for loop in surPlan.loops {
      lines.append("  for (n in 1:N) {")
      lines.append("    row_vector[\(loop.rowDim)] \(loop.meanLocal) = \(loop.meanRhsSource);")
      let distRender = DistributionCatalog.render(loop.distribution)
      lines.append("    \(loop.outcomeName)[n] ~ \(distRender);")
      lines.append("  }")
    }
    lines.append("}")
    return lines.joined(separator: "\n")
  }

  // MARK: - SUR helpers (Slices D + E)

  /// One detected SUR pair: the row-level mean Deterministic plus the
  /// matrix-outcome multi_normal Likelihood it feeds. Emitted as a
  /// single `for (n in 1:N) { … }` block by `modelBlock`.
  struct SurLoop {
    let meanLocal: String        // e.g. "mu"
    let meanRhsSource: String    // e.g. "x[n]*beta"
    let rowDim: String           // J — from cov_matrix parameter's dim
    let outcomeName: String      // e.g. "y"
    let distribution: Distribution
  }

  /// Detection output — the loops to emit + the statement indices to
  /// skip in the regular walk + the local-mean names whose
  /// `vector[N]` top-level declaration should be suppressed (the SUR
  /// emission declares them as `row_vector[J]` inside the loop body).
  struct SurEmissionPlan {
    let loops: [SurLoop]
    let consumedStatements: Set<Int>
    let localMeanNames: Set<String>
  }

  /// Walk the statement list; for each `Likelihood(<matrix-data>,
  /// .multivariateNormal(<mu>, <cov>))` find the matching
  /// `Deterministic(<mu>, <rhs>)` and the `cov_matrix` parameter
  /// `<cov>` (which gives us the row dim). Each matched triple becomes
  /// a `SurLoop`; the two statements are recorded as consumed.
  private static func detectSurLoops(statements: [Statement],
                                     inferred: InferredModel,
                                     matrixDataColumns: Set<String>) -> SurEmissionPlan {
    var loops: [SurLoop] = []
    var consumed: Set<Int> = []
    var localMeans: Set<String> = []

    for (i, stmt) in statements.enumerated() {
      guard case .likelihood(let lhs, let dist, _, _) = stmt else { continue }
      guard matrixDataColumns.contains(lhs) else { continue }
      guard case .multivariateNormal(let muArg, let sigmaArg) = dist else { continue }
      guard case .symbol(let muName) = muArg,
            case .symbol(let sigmaName) = sigmaArg else { continue }
      guard let rowDim = inferred.covMatrixParameters[sigmaName] else { continue }

      var detIdx: Int? = nil
      var detRhsSource: String? = nil
      for (j, other) in statements.enumerated() {
        if case .deterministic(let detLhs, let detRhs) = other, detLhs == muName {
          detIdx = j
          detRhsSource = detRhs.source
          break
        }
      }
      guard let detIdx, let detRhsSource else { continue }

      loops.append(SurLoop(meanLocal: muName,
                           meanRhsSource: detRhsSource,
                           rowDim: rowDim,
                           outcomeName: lhs,
                           distribution: dist))
      consumed.insert(i)
      consumed.insert(detIdx)
      localMeans.insert(muName)
    }
    return SurEmissionPlan(loops: loops,
                           consumedStatements: consumed,
                           localMeanNames: localMeans)
  }

  // MARK: - Monotonic-effects helpers (2026-06-02)

  /// One detected monotonic-effect plan: the Link/Deterministic whose
  /// LHS is `targetLhs`, augmented in place with one or more
  /// `<scale> * sum(<simplex>[1:<predictor>[i]])` terms.
  struct MonoLoop {
    let targetLhs: String
    let combinedBody: String      // base RHS in loop form + monotonic terms
  }

  struct MonoEmissionPlan {
    let loops: [MonoLoop]
    let consumedStatements: Set<Int>
  }

  /// Pair every `MonotonicEffect` with the Link/Deterministic whose LHS
  /// is `targetLhs`; render the base RHS via `renderLoopBody` and
  /// append the monotonic term. Multiple `MonotonicEffect`s targeting
  /// the same LHS chain their contributions into a single for-loop.
  private static func detectMonotonicLoops(
    statements: [Statement],
    inferred: InferredModel
  ) -> MonoEmissionPlan {
    let specs = inferred.monotonicEffects
    if specs.isEmpty { return MonoEmissionPlan(loops: [], consumedStatements: []) }

    let knownVectorParameters = Set(inferred.vectorParameters.keys)
      .union(inferred.nonCenteredVarying.keys)
      .union(inferred.gaussianProcessGP.keys)
    let knownIndexColumns = Set(inferred.indexColumns.keys)
    let knownDataVectors = dataVectorNames(inferred)

    // Group specs by target.
    var specsByTarget: [String: [MonotonicSpec]] = [:]
    for spec in specs {
      specsByTarget[spec.targetLhs, default: []].append(spec)
    }

    var loops: [MonoLoop] = []
    var consumed: Set<Int> = []
    for (target, targetSpecs) in specsByTarget {
      // Locate the matching Link/Deterministic and capture its index.
      for (idx, stmt) in statements.enumerated() {
        switch stmt {
        case .link(let fn, let lhs, let rhs) where lhs == target:
          guard let node = try? rhs.parsed() else { continue }
          let base = renderLoopBody(node,
                                    knownDataVectors: knownDataVectors,
                                    knownIndexColumns: knownIndexColumns,
                                    loopVar: "i")
          let monoTerms = targetSpecs.map(monotonicTerm).joined(separator: " + ")
          let combined = applyInverseLink(fn, to: "\(base) + \(monoTerms)")
          loops.append(MonoLoop(targetLhs: target, combinedBody: combined))
          consumed.insert(idx)
        case .deterministic(let lhs, let rhs) where lhs == target:
          guard let node = try? rhs.parsed() else { continue }
          let base = renderLoopBody(node,
                                    knownDataVectors: knownDataVectors,
                                    knownIndexColumns: knownIndexColumns,
                                    loopVar: "i")
          let monoTerms = targetSpecs.map(monotonicTerm).joined(separator: " + ")
          let combined = "\(base) + \(monoTerms)"
          loops.append(MonoLoop(targetLhs: target, combinedBody: combined))
          consumed.insert(idx)
          // We've also consumed the MonotonicEffect statements themselves;
          // they're declaration-only otherwise.
          _ = knownVectorParameters // silence unused warning if any
        default: break
        }
      }
    }
    // Mark the MonotonicEffect statements as consumed too (model-block
    // emission is a no-op for them, so this is bookkeeping).
    for (idx, stmt) in statements.enumerated() {
      if case .monotonicEffect = stmt { consumed.insert(idx) }
    }
    return MonoEmissionPlan(loops: loops, consumedStatements: consumed)
  }

  /// `<scale> * sum(<name>[1:<predictor>[i]])` per spec.
  private static func monotonicTerm(_ spec: MonotonicSpec) -> String {
    "\(spec.scale) * sum(\(spec.name)[1:\(spec.predictor)[i]])"
  }

  // MARK: - Phase 4 helpers

  enum VectorisationStrategy { case vectorise, loop }

  /// Decide whether a statement's Link/Deterministic RHS can ride
  /// Stan's native vectorised arithmetic, or whether it needs the
  /// `for`-loop emission path. Safe vectorise patterns:
  ///   - `<vec_param>[<idx_col>]` where both halves are known.
  ///   - vector + vector, vector + scalar, scalar * vector — Stan
  ///     overloads these element-wise.
  /// Slice D adds: `vector * vector` (and `vector / vector`) force
  /// loop emission since Stan parses them as matrix multiplication
  /// or dot product, not element-wise. A malformed RHS surfaces as
  /// `BlockEmitterError.malformedExpression`.
  static func vectorisationStrategy(
    for statement: Statement,
    knownVectorParameters: Set<String> = [],
    knownIndexColumns: Set<String> = [],
    knownDataVectors: Set<String> = []
  ) throws -> VectorisationStrategy {
    switch statement {
    case .link(_, _, let rhs), .deterministic(_, let rhs):
      let node = try parseRhs(rhs, symbolForError: statementLhs(statement))
      return classifyVectorisation(node,
                                   knownVectorParameters: knownVectorParameters,
                                   knownIndexColumns: knownIndexColumns,
                                   knownDataVectors: knownDataVectors)
    case .likelihood, .prior, .varyingPrior, .vectorPrior,
         .matrixPrior, .covMatrixPrior, .lkjCorrCholeskyPrior,
         .wishartPrior, .varyingVectorPrior, .gaussianProcessPrior,
         .orderedCutpointsPrior, .simplexPrior, .monotonicEffect,
         .inits, .nestedVaryingPrior, .generatedQuantity:
      // Distribution args are scalars in the current AST (literal or
      // symbol). For varying / vector / matrix / cov_matrix /
      // chol-factor / varying-vector / GP priors, the LHS is a vector-
      // or matrix-typed parameter and Stan vectorises the `~` operator
      // natively over the flattened form. Ordered-cutpoints priors
      // are declaration-only and emit no sampling line.
      return .vectorise
    }
  }

  /// Parse a Link/Deterministic RHS, re-throwing any
  /// `ExpressionParseError` as a `BlockEmitterError.malformedExpression`
  /// tagged with the offending LHS for clearer downstream messages.
  private static func parseRhs(_ rhs: Expression,
                               symbolForError lhs: String) throws -> ExpressionNode {
    do {
      return try rhs.parsed()
    } catch let parseError as ExpressionParseError {
      throw BlockEmitterError.malformedExpression(symbol: lhs,
                                                  underlying: parseError)
    }
  }

  /// Walk a parsed RHS and decide the strategy. Recursive: any
  /// sub-expression that needs a loop forces the whole RHS to the
  /// loop path. The canonical "safe" indexed shape is
  /// `name[ident]` where `name` is a known vector parameter and
  /// `ident` is a known index column. Slice D also routes
  /// `vector * vector` / `vector / vector` to the loop path.
  private static func classifyVectorisation(
    _ node: ExpressionNode,
    knownVectorParameters: Set<String>,
    knownIndexColumns: Set<String>,
    knownDataVectors: Set<String> = []
  ) -> VectorisationStrategy {
    switch node {
    case .indexed(let name, let index):
      guard case .identifier(let idxName) = index else {
        return .loop // nested indexing, or non-identifier index
      }
      if knownVectorParameters.contains(name) && knownIndexColumns.contains(idxName) {
        return .vectorise
      }
      return .loop
    case .binary(let op, let lhs, let rhs):
      // Slice D: `vector * vector` or `vector / vector` is not legal
      // element-wise in Stan — it parses as matrix multiplication /
      // dot product. Route to the loop body translator instead.
      if op == .multiply || op == .divide {
        let leftVec = isVectorTyped(lhs,
                                    knownVectorParameters: knownVectorParameters,
                                    knownIndexColumns: knownIndexColumns,
                                    knownDataVectors: knownDataVectors)
        let rightVec = isVectorTyped(rhs,
                                     knownVectorParameters: knownVectorParameters,
                                     knownIndexColumns: knownIndexColumns,
                                     knownDataVectors: knownDataVectors)
        if leftVec && rightVec { return .loop }
      }
      if classifyVectorisation(lhs,
                               knownVectorParameters: knownVectorParameters,
                               knownIndexColumns: knownIndexColumns,
                               knownDataVectors: knownDataVectors) == .loop {
        return .loop
      }
      return classifyVectorisation(rhs,
                                   knownVectorParameters: knownVectorParameters,
                                   knownIndexColumns: knownIndexColumns,
                                   knownDataVectors: knownDataVectors)
    case .unary(_, let operand):
      return classifyVectorisation(operand,
                                   knownVectorParameters: knownVectorParameters,
                                   knownIndexColumns: knownIndexColumns,
                                   knownDataVectors: knownDataVectors)
    case .call(_, let argument):
      return classifyVectorisation(argument,
                                   knownVectorParameters: knownVectorParameters,
                                   knownIndexColumns: knownIndexColumns,
                                   knownDataVectors: knownDataVectors)
    case .chainedIndexed:
      // Multivariate hierarchical priors Slice D: vector-of-vectors
      // element access always forces the per-row loop emission path —
      // there's no Stan-vectorised form for `ab[cafe][1]`.
      return .loop
    case .subscript2:
      // Nested groupings (2026-06-03): `a[country, region]` matrix
      // lookup is per-row scalar — same loop-emission rationale.
      return .loop
    case .identifier, .literal:
      return .vectorise
    }
  }

  /// Phase 5.5 Slice D: predicate — does this sub-expression evaluate
  /// to a vector at Stan's type level? Used by the classifier to spot
  /// `vector * vector` and by the loop renderer indirectly via
  /// `canLoopEmit`. Vector-typed nodes are:
  ///   - `<vec_param>[<idx_col>]` canonical indexed access
  ///   - identifiers naming a known data vector or vector parameter
  ///   - arithmetic / unary / function-call composed of at least one
  ///     vector operand (Stan overloads `+`, `-`, `*`, `/` to produce
  ///     a vector when at least one operand is one).
  private static func isVectorTyped(
    _ node: ExpressionNode,
    knownVectorParameters: Set<String>,
    knownIndexColumns: Set<String>,
    knownDataVectors: Set<String>
  ) -> Bool {
    switch node {
    case .identifier(let name):
      return knownDataVectors.contains(name) || knownVectorParameters.contains(name)
    case .literal:
      return false
    case .indexed(let name, let idx):
      if knownVectorParameters.contains(name),
         case .identifier(let idxName) = idx,
         knownIndexColumns.contains(idxName) {
        return true
      }
      return false
    case .binary(_, let l, let r):
      return isVectorTyped(l,
                           knownVectorParameters: knownVectorParameters,
                           knownIndexColumns: knownIndexColumns,
                           knownDataVectors: knownDataVectors)
          || isVectorTyped(r,
                           knownVectorParameters: knownVectorParameters,
                           knownIndexColumns: knownIndexColumns,
                           knownDataVectors: knownDataVectors)
    case .unary(_, let op):
      return isVectorTyped(op,
                           knownVectorParameters: knownVectorParameters,
                           knownIndexColumns: knownIndexColumns,
                           knownDataVectors: knownDataVectors)
    case .call(_, let arg):
      return isVectorTyped(arg,
                           knownVectorParameters: knownVectorParameters,
                           knownIndexColumns: knownIndexColumns,
                           knownDataVectors: knownDataVectors)
    case .chainedIndexed:
      // Slice D: chained-indexed access resolves to a scalar element
      // (`ab[cafe][1]` is a scalar real), so it never participates in
      // vectorised vector-vs-vector arithmetic.
      return false
    case .subscript2:
      // Nested groupings: matrix lookup is per-row scalar.
      return false
    }
  }

  /// Phase 5.5 Slice D: predicate — can this RHS be emitted as a
  /// per-row Stan `for (i in 1:N) { ... }` body? An indexed name must
  /// be a known vector parameter (otherwise we'd be emitting
  /// `<scalar>[<...>]` which is invalid Stan and indicates a malformed
  /// model rather than something the loop emitter can fix).
  private static func canLoopEmit(
    _ node: ExpressionNode,
    knownVectorParameters: Set<String>,
    knownVaryingVectorParameters: Set<String> = []
  ) -> Bool {
    switch node {
    case .indexed(let name, let idx):
      if !knownVectorParameters.contains(name) { return false }
      return canLoopEmit(idx,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
    case .binary(_, let l, let r):
      return canLoopEmit(l,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
          && canLoopEmit(r,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
    case .unary(_, let op):
      return canLoopEmit(op,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
    case .call(_, let arg):
      return canLoopEmit(arg,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
    case .chainedIndexed(let name, let outer, let inner):
      // Multivariate hierarchical priors Slice D: only varying-vector
      // parameters can carry `name[outer][inner]` chained access.
      if !knownVaryingVectorParameters.contains(name) { return false }
      return canLoopEmit(outer,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
          && canLoopEmit(inner,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
    case .subscript2(_, let idx1, let idx2):
      // Nested groupings: `a[country, region]` matrix lookup. Recurse
      // into both indices; the outer name is not checked here because
      // matrix-parameter names aren't tracked in either
      // `knownVectorParameters` (vector form) or
      // `knownVaryingVectorParameters` (varying-vector form). The
      // declaration shape is verified at DataInference time instead.
      return canLoopEmit(idx1,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
          && canLoopEmit(idx2,
                         knownVectorParameters: knownVectorParameters,
                         knownVaryingVectorParameters: knownVaryingVectorParameters)
    case .identifier, .literal:
      return true
    }
  }

  /// Phase 5.5 Slice D: translate a parsed RHS into a per-row Stan
  /// expression for use inside a `for (i in 1:N) { ... }` body.
  /// Identifiers naming a known data vector or index column become
  /// `<name>[i]`; everything else (scalar parameters, literals) emits
  /// verbatim. Indexed expressions recurse into the index so
  /// `b[group]` → `b[group[i]]`.
  private static func renderLoopBody(
    _ node: ExpressionNode,
    knownDataVectors: Set<String>,
    knownIndexColumns: Set<String>,
    loopVar: String
  ) -> String {
    let subscriptTargets = knownDataVectors.union(knownIndexColumns)
    return renderLoopBody(node,
                          subscriptTargets: subscriptTargets,
                          loopVar: loopVar)
  }

  private static func renderLoopBody(
    _ node: ExpressionNode,
    subscriptTargets: Set<String>,
    loopVar: String
  ) -> String {
    switch node {
    case .identifier(let name):
      if subscriptTargets.contains(name) { return "\(name)[\(loopVar)]" }
      return name
    case .literal(.integer(let v)):
      return String(v)
    case .literal(.float(let v)):
      return String(v)
    case .indexed(let name, let idx):
      let inner = renderLoopBody(idx,
                                 subscriptTargets: subscriptTargets,
                                 loopVar: loopVar)
      return "\(name)[\(inner)]"
    case .binary(let op, let l, let r):
      let lr = renderLoopBody(l, subscriptTargets: subscriptTargets, loopVar: loopVar)
      let rr = renderLoopBody(r, subscriptTargets: subscriptTargets, loopVar: loopVar)
      // Re-add parens around a child binary whose precedence is lower
      // than this node's — the source-level grouping is lost in the AST,
      // so without this `(a + b) * x` would round-trip as `a + b*x`.
      let lw = wrapChild(l, rendered: lr, parent: op)
      let rw = wrapChild(r, rendered: rr, parent: op)
      switch op {
      case .add:      return "\(lw) + \(rw)"
      case .subtract: return "\(lw) - \(rw)"
      case .multiply: return "\(lw)*\(rw)"
      case .divide:   return "\(lw)/\(rw)"
      }
    case .unary(.negate, let op):
      let inner = renderLoopBody(op,
                                 subscriptTargets: subscriptTargets,
                                 loopVar: loopVar)
      return "-\(inner)"
    case .call(let name, let arg):
      let inner = renderLoopBody(arg,
                                 subscriptTargets: subscriptTargets,
                                 loopVar: loopVar)
      return "\(name)(\(inner))"
    case .chainedIndexed(let name, let outer, let inner):
      // Multivariate hierarchical priors Slice D: `ab[cafe][1]` →
      // `ab[cafe[i]][1]`. The outer index (typically the group-id
      // column) gets subscripted via the standard data-vector path;
      // the inner index renders as-is (literal slot number).
      let outerRendered = renderLoopBody(outer,
                                         subscriptTargets: subscriptTargets,
                                         loopVar: loopVar)
      let innerRendered = renderLoopBody(inner,
                                         subscriptTargets: subscriptTargets,
                                         loopVar: loopVar)
      return "\(name)[\(outerRendered)][\(innerRendered)]"
    case .subscript2(let name, let idx1, let idx2):
      // Nested groupings: `a[country, region]` → `a[country[i], region[i]]`.
      // Both index columns are subscripted via the standard data-vector
      // path; the result is one Stan-valid matrix lookup.
      let r1 = renderLoopBody(idx1,
                              subscriptTargets: subscriptTargets,
                              loopVar: loopVar)
      let r2 = renderLoopBody(idx2,
                              subscriptTargets: subscriptTargets,
                              loopVar: loopVar)
      return "\(name)[\(r1), \(r2)]"
    }
  }

  private static func binaryPrecedence(_ op: BinaryOp) -> Int {
    switch op {
    case .add, .subtract:    return 1
    case .multiply, .divide: return 2
    }
  }

  private static func wrapChild(_ child: ExpressionNode,
                                rendered: String,
                                parent: BinaryOp) -> String {
    guard case .binary(let childOp, _, _) = child else { return rendered }
    if binaryPrecedence(childOp) < binaryPrecedence(parent) {
      return "(\(rendered))"
    }
    return rendered
  }

  /// Phase 5.5 Slice D: which data columns end up as `vector[N]` in
  /// the data block — real columns plus Slice-C-promoted int columns.
  /// Drives `isVectorTyped` and the loop-body subscripting decision.
  private static func dataVectorNames(_ inferred: InferredModel) -> Set<String> {
    var result: Set<String> = []
    for (name, col) in inferred.dataVectors {
      switch col {
      case .real:
        result.insert(name)
      case .integer:
        if inferred.promotedIntColumns.contains(name) {
          result.insert(name)
        }
      default:
        break
      }
    }
    return result
  }

  private static func statementLhs(_ statement: Statement) -> String {
    switch statement {
    case .likelihood(let lhs, _, _, _):       return lhs
    case .prior(let name, _, _, _, _, _):     return name
    case .varyingPrior(let name, _, _, _, _, _, _, _, _): return name
    case .vectorPrior(let name, _, _, _, _):  return name
    case .matrixPrior(let name, _, _, _, _, _): return name
    case .covMatrixPrior(let name, _):           return name
    case .lkjCorrCholeskyPrior(let name, _, _): return name
    case .wishartPrior(let name, _, _, _):       return name
    case .varyingVectorPrior(let name, _, _, _, _, _, _): return name
    case .gaussianProcessPrior(let name, _, _, _, _, _):  return name
    case .orderedCutpointsPrior(let name, _):    return name
    case .simplexPrior(let name, _):             return name
    case .monotonicEffect(let name, _, _, _, _): return name
    case .inits:                              return ""
    case .nestedVaryingPrior(let name, _, _, _, _, _): return name
    case .link(_, let lhs, _):                return lhs
    case .deterministic(let lhs, _):          return lhs
    case .generatedQuantity(let name, _):     return name
    }
  }

  private static func renderBounds(_ bounds: DistributionCatalog.OutcomeBounds?) -> String {
    guard let bounds, !bounds.isEmpty else { return "" }
    var parts: [String] = []
    if let lower = bounds.lower { parts.append("lower=\(lower)") }
    if let upper = bounds.upper { parts.append("upper=\(upper)") }
    return "<" + parts.joined(separator: ", ") + ">"
  }

  /// Emit a single sampling line for a prior or likelihood. Handles both
  /// the `lhs ~ dist(args) T[...];` form and the
  /// `target += dist_lp[m]df(lhs | args);` form. Rejects truncation
  /// combined with `useLpdf` (Stan's truncation auto-normalisation only
  /// applies to the `~` form).
  private static func emitSampling(lhs: String,
                                   distribution: Distribution,
                                   truncation: Truncation,
                                   useLpdf: Bool) throws -> String {
    // Phase 6: Stan doesn't accept `T[...]` on multivariate
    // distributions. Catch this before either form below renders.
    if !truncation.isEmpty && DistributionCatalog.isMultivariate(distribution) {
      throw BlockEmitterError.multivariateTruncationUnsupported(symbol: lhs)
    }
    if useLpdf {
      if !truncation.isEmpty {
        throw BlockEmitterError.truncationWithLpdf(symbol: lhs)
      }
      let suffix = DistributionCatalog.isDiscrete(distribution) ? "_lpmf" : "_lpdf"
      return "  target += \(DistributionCatalog.name(distribution))\(suffix)(\(lhs) | \(DistributionCatalog.args(distribution)));"
    } else {
      let truncSuffix = DistributionCatalog.renderTruncation(truncation)
      return "  \(lhs) ~ \(DistributionCatalog.render(distribution))\(truncSuffix);"
    }
  }

  /// `logit(p) <- rhs` ⟹ `p = inv_logit(rhs)`, etc.
  private static func applyInverseLink(_ function: LinkFunction, to rhs: String) -> String {
    switch function {
    case .logit:    return "inv_logit(\(rhs))"
    case .log:      return "exp(\(rhs))"
    case .invLogit: return "logit(\(rhs))"
    }
  }
}

enum BlockEmitterError: Error, CustomStringConvertible {
  case truncationWithLpdf(symbol: String)
  case loopEmissionRequired(symbol: String)
  case multivariateTruncationUnsupported(symbol: String)
  case malformedExpression(symbol: String, underlying: ExpressionParseError)

  var description: String {
    switch self {
    case .truncationWithLpdf(let s):
      return "ulam: '\(s)' uses both truncation and useLpdf — Stan's truncation auto-normalisation only applies to the `~` sampling form, not the `target += ..._lpdf` form."
    case .loopEmissionRequired(let s):
      return "ulam: '\(s)' has an indexed RHS that needs Stan loop emission — that path is reserved for Phase 5 (multilevel/varying effects). For now, rewrite without subscripted symbols."
    case .multivariateTruncationUnsupported(let s):
      return "ulam: '\(s)' uses a multivariate distribution with truncation — Stan's `T[...]` syntax only supports univariate distributions"
    case .malformedExpression(let s, let underlying):
      return "ulam: RHS of '\(s)' could not be parsed: \(underlying)"
    }
  }
}
