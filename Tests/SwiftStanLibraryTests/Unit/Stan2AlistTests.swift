//
//  Stan2AlistTests.swift
//  StanTests
//
//  Slice A of Docs/Stan2AlistCommandPlan.md — the reverse distribution
//  catalog. Locks in that `distribution(fromStanName:args:)` is the
//  exact inverse of `name(_:)` + `args(_:)` for every univariate
//  distribution in v1 scope, and that unsupported / mis-arity inputs
//  fail loud.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("stan2alist tests")
struct Stan2AlistTests {

  /// Representative univariate distributions with a mix of literal,
  /// symbol, and compound-expression arguments. Every one must survive
  /// the `Distribution → render → reverse` round trip unchanged.
  static let roundTripCases: [Distribution] = [
    .normal(0, 10),
    .normal("mu_alpha", "sigma_alpha"),
    .normal(.expression("a + b*x"), "sigma"),
    .bernoulli(p: "p"),
    .binomial(n: 1, p: "p"),
    .beta(2, 2),
    .exponential(1),
    .poisson("lambda"),
    .gamma(2, "rate"),
    .cauchy(0, 1),
    .lognormal(0, "sigma"),
    .uniform(lower: 0, upper: 50),
    .studentT(nu: 3, mu: 0, sigma: "sigma"),
    // Multivariate distributions (M2 catalog additions).
    // Use simple identifier args — no inner commas — because the symmetry
    // test splits the rendered arg string on ", " and compound expressions
    // like `diag_pre_multiply(x, y)` would split mid-call.
    .multivariateNormal(mu: "mu", sigma: "Sigma"),
    .multivariateNormalCholesky(mean: "mu_ab", chol: "L"),
    .lkjCorrCholesky(2),
    .wishart(nu: 3, V: "S"),
  ]

  @Test("reverse catalog is the inverse of the forward catalog")
  func reverseCatalogIsSymmetric() throws {
    for distribution in Self.roundTripCases {
      let stanName = DistributionCatalog.name(distribution)
      let argStrings = DistributionCatalog.args(distribution)
        .components(separatedBy: ", ")
      let rebuilt = try DistributionCatalog.distribution(fromStanName: stanName,
                                                         args: argStrings)
      #expect(rebuilt == distribution,
              "round trip drifted for \(distribution): got \(rebuilt)")
    }
  }

  // multi_normal and other multivariate distributions are now supported in
  // the reverse catalog (M2). Symmetry is verified by `reverseCatalogIsSymmetric`
  // above via the `roundTripCases` array. An arity mismatch on a multivariate
  // distribution still fails loud (covered by `arityMismatchThrows` below).

  @Test("argument-count mismatch fails loud")
  func arityMismatchThrows() {
    #expect(throws: DistributionCatalog.ReverseError.self) {
      _ = try DistributionCatalog.distribution(fromStanName: "normal",
                                               args: ["0"])
    }
  }

  @Test("argument classification splits literal / symbol / expression")
  func argClassification() {
    #expect(DistributionCatalog.distributionArg(from: "10") == .literal(10))
    #expect(DistributionCatalog.distributionArg(from: " 0.5 ") == .literal(0.5))
    #expect(DistributionCatalog.distributionArg(from: "sigma") == .symbol("sigma"))
    #expect(DistributionCatalog.distributionArg(from: "mu_alpha") == .symbol("mu_alpha"))
    #expect(DistributionCatalog.distributionArg(from: "alpha[county] + beta*floor")
            == .expression("alpha[county] + beta*floor"))
  }

  // MARK: - Slice B: StanBlockParser

  /// The hand-written radon_pp.stan from ~/Documents/StanCases/radon_pp —
  /// exercises comments, an inline linear model, an `offset/multiplier`
  /// affine parameter, and a `generated quantities` block.
  static let radonPpStan = """
  data {
    int<lower=1> N;  // observations
    int<lower=1> N_county;
    array[N] int<lower=1, upper=N_county> county;
    vector[N] floor;
    vector[N] log_radon;
  }
  parameters {
    real mu_alpha;
    real<lower=0> sigma_alpha;
    vector<offset=mu_alpha, multiplier=sigma_alpha>[N_county] alpha;
    real beta;
    real<lower=0> sigma;
  }
  model {
    log_radon ~ normal(alpha[county] + beta * floor, sigma);
    alpha ~ normal(mu_alpha, sigma_alpha); // partial-pooling
    beta ~ normal(0, 10);
    sigma ~ normal(0, 10);
    mu_alpha ~ normal(0, 10);
    sigma_alpha ~ normal(0, 10);
  }
  generated quantities {
    array[N] real y_rep = normal_rng(alpha[county] + beta * floor, sigma);
  }
  """

  @Test("parses radon_pp.stan into a structured StanProgram")
  func parsesRadonPpStan() throws {
    let program = try StanBlockParser.parse(Self.radonPpStan)

    // Data block: N, N_county, county, floor, log_radon.
    #expect(program.dataDecls.map(\.name) == ["N", "N_county", "county", "floor", "log_radon"])
    let county = try #require(program.dataDecls.first { $0.name == "county" })
    #expect(county.type == .arrayInt(size: "N"))
    #expect(county.constraints.lower == "1")
    #expect(county.constraints.upper == "N_county")
    let logRadon = try #require(program.dataDecls.first { $0.name == "log_radon" })
    #expect(logRadon.type == .vector(size: "N"))

    // Parameters: the affine `alpha` is the interesting one.
    #expect(program.parameterDecls.map(\.name)
            == ["mu_alpha", "sigma_alpha", "alpha", "beta", "sigma"])
    let alpha = try #require(program.parameterDecls.first { $0.name == "alpha" })
    #expect(alpha.type == .vector(size: "N_county"))
    #expect(alpha.constraints.offset == "mu_alpha")
    #expect(alpha.constraints.multiplier == "sigma_alpha")
    let sigma = try #require(program.parameterDecls.first { $0.name == "sigma" })
    #expect(sigma.type == .real)
    #expect(sigma.constraints.lower == "0")

    // Model block: 6 sampling statements, the first with an inline
    // linear-model expression that must survive bracket-aware splitting.
    #expect(program.modelStatements.count == 6)
    guard case let .sampling(lhs, distName, args, trunc) = program.modelStatements[0] else {
      Issue.record("expected first model statement to be a sampling line")
      return
    }
    #expect(lhs == "log_radon")
    #expect(distName == "normal")
    #expect(args == ["alpha[county] + beta * floor", "sigma"])
    #expect(trunc == nil)

    // generated quantities is parsed into gqStatements, not dropped.
    #expect(program.droppedBlocks == [])
    #expect(program.gqStatements.count == 1)
    if case let .assignment(gqLhs, gqRhs) = program.gqStatements[0] {
      #expect(gqLhs.hasSuffix("y_rep"))
      #expect(gqRhs.hasPrefix("normal_rng("))
    } else {
      Issue.record("expected GQ statement to be an assignment")
    }
  }

  @Test("a model line that is neither sampling nor assignment fails loud")
  func rejectsUnknownModelStatement() {
    let src = """
    model {
      this is not valid stan;
    }
    """
    #expect(throws: StanBlockParseError.self) {
      _ = try StanBlockParser.parse(src)
    }
  }

  @Test("an unrecognized top-level block fails loud")
  func rejectsUnknownTopLevel() {
    let src = "banana { real x; }"
    #expect(throws: StanBlockParseError.self) {
      _ = try StanBlockParser.parse(src)
    }
  }

  @Test("parses a truncated sampling statement")
  func parsesTruncation() throws {
    let program = try StanBlockParser.parse("model { sigma ~ normal(0, 10) T[0, ]; }")
    guard case let .sampling(_, _, _, trunc) = program.modelStatements[0] else {
      Issue.record("expected a sampling statement")
      return
    }
    #expect(trunc == StanTruncation(lower: "0", upper: nil))
  }

  // MARK: - Slice C: StanToUlamModel

  @Test("reconstructs radon_pp statements from the parsed program")
  func reconstructsRadonPpStatements() throws {
    let program = try StanBlockParser.parse(Self.radonPpStan)
    let result = try StanToUlamModel.build(program)

    let expected: [Statement] = [
      // Priors are now in parameter-declaration order (mu_alpha, sigma_alpha,
      // alpha, beta, sigma) — the forward emitter uses declaration order so
      // the byte-identical oracle is preserved.
      .likelihood(lhs: "log_radon",
                  distribution: .normal(.expression("alpha[county] + beta * floor"), "sigma"),
                  truncation: .none,
                  useLpdf: false),
      .prior(name: "mu_alpha", distribution: .normal(0, 10),
             truncation: .none, constraints: .none, start: nil, useLpdf: false),
      .prior(name: "sigma_alpha", distribution: .normal(0, 10),
             truncation: .none, constraints: .none, start: nil, useLpdf: false),
      .varyingPrior(name: "alpha",
                    indexedBy: "county",
                    countSymbol: nil,
                    distribution: .normal("mu_alpha", "sigma_alpha"),
                    truncation: .none,
                    constraints: .none,
                    start: nil,
                    useLpdf: false,
                    nonCentered: false),
      .prior(name: "beta", distribution: .normal(0, 10),
             truncation: .none, constraints: .none, start: nil, useLpdf: false),
      .prior(name: "sigma", distribution: .normal(0, 10),
             truncation: .none, constraints: .none, start: nil, useLpdf: false),
      .generatedQuantity(name: "y_rep",
                         distribution: .normal(.expression("alpha[county] + beta * floor"), "sigma")),
    ]

    #expect(result.statements == expected)
    // The GQ block is now parsed — no warning expected.
    #expect(result.warnings.isEmpty)
  }

  @Test("inv_logit assignment becomes a logit link")
  func reconstructsLogitLink() throws {
    let src = """
    data { int<lower=1> N; array[N] int<lower=0, upper=1> y; vector[N] x; }
    parameters { real a; real b; }
    model {
      p = inv_logit(a + b*x);
      y ~ bernoulli(p);
      a ~ normal(0, 1);
      b ~ normal(0, 1);
    }
    """
    let program = try StanBlockParser.parse(src)
    let result = try StanToUlamModel.build(program)

    // Likelihood first, then the link, then the priors.
    #expect(result.statements.first == .likelihood(
      lhs: "y", distribution: .bernoulli(p: "p"), truncation: .none, useLpdf: false))
    #expect(result.statements.contains(
      .link(function: .logit, lhs: "p", rhs: Expression("a + b*x"))))
  }

  @Test("a model with no data-outcome sampling line fails loud")
  func reconstructNoLikelihoodThrows() throws {
    let src = """
    parameters { real a; }
    model { a ~ normal(0, 1); }
    """
    let program = try StanBlockParser.parse(src)
    #expect(throws: StanToUlamError.self) {
      _ = try StanToUlamModel.build(program)
    }
  }

  // MARK: - Slice D: AlistTextEmitter

  @Test("emits radon_pp statements as McElreath alist text")
  func emitsRadonPpAlist() throws {
    let program = try StanBlockParser.parse(Self.radonPpStan)
    let statements = try StanToUlamModel.build(program).statements
    let text = try AlistTextEmitter.emit(statements)

    // Priors in parameter-declaration order: mu_alpha, sigma_alpha, alpha, beta, sigma.
    let expected = """
    alist(
      log_radon ~ dnorm(alpha[county] + beta * floor, sigma),
      mu_alpha ~ dnorm(0, 10),
      sigma_alpha ~ dnorm(0, 10),
      alpha[county] ~ dnorm(mu_alpha, sigma_alpha),
      beta ~ dnorm(0, 10),
      sigma ~ dnorm(0, 10),
      y_rep <- sim(dnorm(alpha[county] + beta * floor, sigma))
    )

    """
    #expect(text == expected)
  }

  @Test("emitted alist re-parses through AlistParser")
  func emittedAlistReparses() throws {
    let program = try StanBlockParser.parse(Self.radonPpStan)
    let statements = try StanToUlamModel.build(program).statements
    let text = try AlistTextEmitter.emit(statements)

    let parsed = try AlistParser.parse(text)
    // 6 priors/likelihood + 1 sim() line = 7 statements.
    #expect(parsed.count == 7)
    // First statement is the likelihood over the scalar outcome.
    guard case let .sample(lhs, dist, _) = parsed.first else {
      Issue.record("expected first parsed statement to be a sample")
      return
    }
    #expect(lhs == .scalar("log_radon"))
    #expect(dist.name == "dnorm")
    // The varying prior keeps its `[county]` index.
    #expect(parsed.contains { stmt in
      if case let .sample(lhs, _, _) = stmt {
        return lhs == .indexed(name: "alpha", indexColumn: "county")
      }
      return false
    })
    // The sim() line re-parses as a generatedQuantity statement.
    #expect(parsed.contains { stmt in
      if case let .generatedQuantity(target, dist) = stmt {
        return target == "y_rep" && dist.name == "dnorm"
      }
      return false
    })
  }

  @Test("bernoulli renders as dbinom(1, p) and inv_logit as a logit link")
  func emitsBernoulliAndLink() throws {
    let statements: [Statement] = [
      .likelihood(lhs: "y", distribution: .bernoulli(p: "p"),
                  truncation: .none, useLpdf: false),
      .link(function: .logit, lhs: "p", rhs: Expression("a + b*x")),
      .prior(name: "a", distribution: .normal(0, 1.5),
             truncation: .none, constraints: .none, start: nil, useLpdf: false),
    ]
    let text = try AlistTextEmitter.emit(statements)
    #expect(text.contains("y ~ dbinom(1, p)"))
    #expect(text.contains("logit(p) <- a + b*x"))
    #expect(text.contains("a ~ dnorm(0, 1.5)"))
  }

  // MARK: - T1: AlistLexer prime token (Docs/AlistTransposePlan.md)

  @Test("AlistLexer does not crash on `'` (postfix transpose) character")
  func primeLexerNoCrash() throws {
    // `'` must produce a `.prime` token rather than throwing.
    let tokens = try AlistLexer.tokenize("alist( a ~ dnorm([mu, 0]', sigma) )")
    #expect(tokens.contains { $0.kind == .prime })
  }

  // MARK: - T2: parseBracketVectorArg (Docs/AlistTransposePlan.md)

  @Test("[a, b]' as a distribution arg is equivalent to c(a, b)")
  func bracketVectorArgEquivalentToCVector() throws {
    // Both forms should parse to the same AlistDistribution args.
    let bracketForm = "alist( x ~ dnorm(0, 1), ab[g] ~ dmvnorm2([a, b]', sigma, L) )"
    let cForm       = "alist( x ~ dnorm(0, 1), ab[g] ~ dmvnorm2(c(a, b), sigma, L) )"
    let bracketStmts = try AlistParser.parse(bracketForm)
    let cStmts       = try AlistParser.parse(cForm)
    guard bracketStmts.count == 2, cStmts.count == 2 else {
      Issue.record("expected 2 statements in each"); return
    }
    guard case let .sample(_, bracketDist, _) = bracketStmts[1],
          case let .sample(_, cDist, _) = cStmts[1] else {
      Issue.record("expected sample statements"); return
    }
    // Mean arg (args[0]) must be .identifier("[a, b]'") in both forms.
    #expect(bracketDist.args == cDist.args)
  }

  // MARK: - T3: lowerPackedIndexed (Docs/AlistTransposePlan.md)

  @Test("indexed LHS + dmvnorm2 lowers to varyingVectorSample (T3)")
  func indexedLhsDmvnorm2LowersToVaryingVector() throws {
    let alist = """
    alist(
      wait ~ dnorm(mu, sigma),
      ab[cafe] ~ dmvnorm2(c(a_bar, b_bar), sigma_ab, L_Omega)
    )
    """
    let parsed = try AlistParser.parse(alist)
    let lowered = try AlistLowering.lower(parsed)
    guard lowered.count == 2,
          case let .varyingVectorSample(name, indexedBy, length, _, sigmaName, dist, _)
            = lowered[1] else {
      Issue.record("expected varyingVectorSample at index 1, got \(lowered)"); return
    }
    #expect(name == "ab")
    #expect(indexedBy == "cafe")
    #expect(length == 2)
    #expect(sigmaName == "sigma_ab")
    guard case .multivariateNormalCholesky = dist else {
      Issue.record("expected multivariateNormalCholesky distribution"); return
    }
  }

  // MARK: - T4: AlistTextEmitter dmvnorm2 rendering (Docs/AlistTransposePlan.md)

  @Test("varyingVectorPrior+multivariateNormalCholesky emits dmvnorm2(c(...)) without `'`")
  func varyingVectorPriorEmitsDmvnorm2() throws {
    let statements: [Statement] = [
      .likelihood(lhs: "wait", distribution: .normal("mu", "sigma"),
                  truncation: .none, useLpdf: false),
      .varyingVectorPrior(name: "ab", indexedBy: "cafe", length: "J",
                          countSymbol: nil,
                          distribution: .multivariateNormalCholesky(
                            mean: .expression("[a_bar, b_bar]'"),
                            chol: .expression("diag_pre_multiply(sigma_ab, L_Omega)")),
                          truncation: .none,
                          useLpdf: false),
    ]
    let text = try AlistTextEmitter.emit(statements)
    #expect(text.contains("ab[cafe] ~ dmvnorm2(c(a_bar, b_bar), sigma_ab, L_Omega)"),
            "emitter must use dmvnorm2(c(...), ...) form, got:\n\(text)")
    #expect(!text.contains("'"),
            "emitter output must not contain the transpose `'` character:\n\(text)")
  }

  // MARK: - Slice E: stan2alist command

  @Suite("stan2alist command tests")
  struct CommandTests {
    init() { _ = TestCaseRootBootstrap.install }

    @Test("writes Preliminaries/<name>.alist.R from Results/<name>.stan")
    func writesAlistFromStan() throws {
      let model = "stan2alist_radon_fixture"
      let paths = casePaths(for: model)
      try ensureCaseDirectories(paths)
      defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

      try Stan2AlistTests.radonPpStan.write(
        to: paths.results.appendingPathComponent("\(model).stan"),
        atomically: true, encoding: .utf8)

      let outURL = try stan2alist(model: model)
      #expect(outURL == paths.preliminaries.appendingPathComponent("\(model).alist.R"))

      let written = try String(contentsOf: outURL, encoding: .utf8)
      #expect(written.contains("log_radon ~ dnorm(alpha[county] + beta * floor, sigma)"))
      #expect(written.contains("alpha[county] ~ dnorm(mu_alpha, sigma_alpha)"))
    }

    @Test("refuses to overwrite an existing alist without --force")
    func overwriteGuard() throws {
      let model = "stan2alist_force_fixture"
      let paths = casePaths(for: model)
      try ensureCaseDirectories(paths)
      defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

      try Stan2AlistTests.radonPpStan.write(
        to: paths.results.appendingPathComponent("\(model).stan"),
        atomically: true, encoding: .utf8)
      // Pre-existing hand-authored alist that must not be clobbered.
      let alistURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")
      try "# hand-authored — keep me\n".write(to: alistURL, atomically: true, encoding: .utf8)

      #expect(throws: Stan2AlistError.self) {
        _ = try stan2alist(model: model)
      }
      // The original file is untouched.
      let preserved = try String(contentsOf: alistURL, encoding: .utf8)
      #expect(preserved.contains("hand-authored"))

      // With --force it overwrites.
      _ = try stan2alist(model: model, force: true)
      let overwritten = try String(contentsOf: alistURL, encoding: .utf8)
      #expect(overwritten.contains("log_radon ~ dnorm"))
    }

    @Test("missing Results/<name>.stan fails loud")
    func missingStanFile() throws {
      let model = "stan2alist_missing_fixture"
      let paths = casePaths(for: model)
      try ensureCaseDirectories(paths)
      defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

      #expect(throws: Stan2AlistError.self) {
        _ = try stan2alist(model: model)
      }
    }

    // MARK: - Slice F: round-trip oracle

    /// `howell` (scalar baseline) and a multilevel radon-style alist that
    /// exercises a varying prior (`alpha[county]`), a vectorising
    /// deterministic link (`mu <- alpha[county] + beta*floor`), and
    /// half-Cauchy scales (the `T[0, ]` / `<lower=0>` round-trip). Both
    /// vectorise. `chimpanzees` exercises the loop path: its `vector *
    /// vector` term forces the generator into a `for (i in 1:N)` loop,
    /// which `StanBlockParser` now inverts back into the vectorised
    /// assignment (see Docs/LoopEmissionPlan.md), so it round-trips too.
    static let multilevelAlist = """
    alist(
      log_radon ~ dnorm( mu , sigma ),
      mu <- alpha[county] + beta*floor,
      alpha[county] ~ dnorm( a_bar , sigma_alpha ),
      a_bar ~ dnorm( 0 , 10 ),
      beta ~ dnorm( 0 , 10 ),
      sigma ~ dcauchy( 0 , 1 ),
      sigma_alpha ~ dcauchy( 0 , 1 )
    )
    """

    /// For a generator-produced `.stan`, `stan2alist` followed by
    /// `stancode` must reproduce the original Stan byte-for-byte. The
    /// flow: stage the alist → stancode (original) → stan2alist
    /// (force-overwrites the alist) → stancode (round-trip) → compare.
    @Test("alist → stancode → stan2alist → stancode round-trips byte-identically",
          arguments: ["howell", "multilevel", "chimpanzees"])
    func roundTripsThroughStancode(_ fixture: String) throws {
      let model = "stan2alist_roundtrip_\(fixture)"
      let paths = casePaths(for: model)
      try ensureCaseDirectories(paths)
      defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

      let alistURL = paths.preliminaries.appendingPathComponent("\(model).alist.R")
      if fixture == "multilevel" {
        try Self.multilevelAlist.write(to: alistURL, atomically: true, encoding: .utf8)
      } else {
        try stageBundledFixture(named: "\(fixture).alist.R", to: alistURL)
      }

      // Forward: alist → original Stan.
      let original = try String(contentsOf: stancode(model: model), encoding: .utf8)

      // Reverse: Stan → alist (force-overwrites the staged alist).
      _ = try stan2alist(model: model, force: true)

      // Forward again: reconstructed alist → Stan.
      let roundtrip = try String(contentsOf: stancode(model: model), encoding: .utf8)

      #expect(roundtrip == original,
              "round-trip diverged for \(fixture):\n--- original ---\n\(original)\n--- roundtrip ---\n\(roundtrip)")
    }

    /// `StanBlockParser` handles the exact 1- and 2-statement contract
    /// loops the forward emitter produces. A 3-statement body, a `while`,
    /// or a non-`1:N` bound is genuinely off-contract and must still fail
    /// loud rather than mis-parse.
    @Test("an off-contract loop body fails loud")
    func offContractLoopFailsLoud() throws {
      let model = "stan2alist_loop_fixture"
      let paths = casePaths(for: model)
      try ensureCaseDirectories(paths)
      defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

      // Three statements in the loop body — beyond the 2-statement SUR contract.
      let offContract = """
      data {
        int<lower=0> N;
        matrix[N, 2] y;
        matrix[N, 2] x;
        int J;
        int K;
      }
      parameters {
        matrix[K, J] beta;
        cov_matrix[J] Sigma;
        real extra;
      }
      model {
        for (n in 1:N) {
          row_vector[J] mu = x[n]*beta;
          real z = extra + 1;
          y[n] ~ multi_normal(mu, Sigma);
        }
      }
      """
      try offContract.write(
        to: paths.results.appendingPathComponent("\(model).stan"),
        atomically: true, encoding: .utf8)

      #expect(throws: Stan2AlistError.self) {
        _ = try stan2alist(model: model, force: true)
      }
    }

    // MARK: - Multivariate oracle: Stan → [Statement] → stancode byte-identical

    /// Family A oracle: `StanBlockParser` + `StanToUlamModel` reconstruct the
    /// exact `[Statement]` list from the cafe varying-slopes golden, and
    /// `stancode` re-emits the same Stan byte-for-byte.
    /// The full alist-text round-trip for Family A is covered by
    /// `cafeAlistFullRoundTrip` below (T5, Docs/AlistTransposePlan.md).
    @Test("Family A (cafe varying-slopes) Stan → parse → stancode is byte-identical")
    func cafeMultivariateRoundTrip() throws {
      let original = """
      // Generated by SwiftStan ulam port.
      data {
        int<lower=1> N;
        int<lower=1> N_cafe;
        vector[N] afternoon;
        array[N] int<lower=1, upper=N_cafe> cafe;
        vector[N] wait;
        int J;
      }
      parameters {
        real a_bar;
        real b_bar;
        real<lower=0> sigma;
        vector<lower=0>[J] sigma_ab;
        cholesky_factor_corr[J] L_Omega;
        array[N_cafe] vector[J] ab;
      }
      model {
        vector[N] mu;
        for (i in 1:N) {
          mu[i] = ab[cafe[i]][1] + ab[cafe[i]][2]*afternoon[i];
        }
        a_bar ~ normal(0, 5);
        b_bar ~ normal(0, 5);
        sigma ~ exponential(1) T[0, ];
        sigma_ab ~ exponential(1) T[0, ];
        L_Omega ~ lkj_corr_cholesky(2);
        ab ~ multi_normal_cholesky([a_bar, b_bar]', diag_pre_multiply(sigma_ab, L_Omega));
        wait ~ normal(mu, sigma);
      }
      """
      let program = try StanBlockParser.parse(original)
      let result = try StanToUlamModel.build(program)
      let data: UlamData = [
        "afternoon": .real([0.0, 1.0, 0.0, 1.0, 0.0, 1.0]),
        "cafe":      .integer([1, 1, 2, 2, 3, 3]),
        "wait":      .real([3.0, 2.5, 3.2, 3.0, 4.0, 3.8]),
        "J":         .scalarInt(2),
      ]
      let rebuilt = UlamModel(data: data, statements: result.statements)
      let roundtrip = try stancode(rebuilt)
      #expect(roundtrip == original,
              "cafe round-trip diverged:\n--- original ---\n\(original)\n--- roundtrip ---\n\(roundtrip)")
    }

    /// Family B oracle: `StanBlockParser` + `StanToUlamModel` reconstruct the
    /// SUR WaffleDivorce model from its Stan golden, and `stancode` re-emits
    /// the same Stan byte-for-byte.
    @Test("Family B (SUR) Stan → parse → stancode is byte-identical")
    func surMultivariateRoundTrip() throws {
      let original = """
      // Generated by SwiftStan ulam port.
      data {
        int<lower=1> N;
        matrix[N, 2] x;
        matrix[N, 2] y;
        int J;
        int K;
      }
      parameters {
        matrix[K, J] beta;
        cov_matrix[J] Sigma;
      }
      model {
        to_vector(beta) ~ normal(0, 1);
        for (n in 1:N) {
          row_vector[J] mu = x[n]*beta;
          y[n] ~ multi_normal(mu, Sigma);
        }
      }
      """
      let program = try StanBlockParser.parse(original)
      let result = try StanToUlamModel.build(program)
      let data: UlamData = [
        "K": .scalarInt(2),
        "J": .scalarInt(2),
        "x": .realMatrix(rows: 3, cols: 2, values: [[1, 25.3], [1, 26.0], [1, 25.8]]),
        "y": .realMatrix(rows: 3, cols: 2, values: [[12.7, 20.2], [11.0, 18.6], [13.5, 21.0]]),
      ]
      let rebuilt = UlamModel(data: data, statements: result.statements)
      let roundtrip = try stancode(rebuilt)
      #expect(roundtrip == original,
              "SUR round-trip diverged:\n--- original ---\n\(original)\n--- roundtrip ---\n\(roundtrip)")
    }

    // MARK: - T5: full alist-text round-trip oracle (Docs/AlistTransposePlan.md)

    /// `alist → stancode → stan2alist → alist → stancode` byte-identical
    /// for a cafe-style varying-slopes model. Exercises T4 (emitter uses
    /// `dmvnorm2(c(...), sigma, L)` form without `'`), T3 (indexed-LHS
    /// multivariate lowering), and AlistLexer T1 (prime token accepted).
    ///
    /// Uses the packed `ab[cafe]` form in both the linear model and the
    /// prior — component name recovery is a documented loss (§6 of plan).
    @Test("cafe-style alist → stancode → stan2alist → stancode round-trips byte-identically")
    func cafeAlistFullRoundTrip() throws {
      let model = "stan2alist_cafe_alist_roundtrip"
      let paths = casePaths(for: model)
      try ensureCaseDirectories(paths)
      defer { try? FileManager.default.removeItem(at: caseRoot().appendingPathComponent(model)) }

      let cafeAlist = """
      alist(
        wait ~ dnorm( mu , sigma ),
        mu <- ab[cafe][1] + ab[cafe][2]*afternoon,
        ab[cafe] ~ dmvnorm2(c(a_bar, b_bar), sigma_ab, L_Omega),
        a_bar ~ dnorm(0, 5),
        b_bar ~ dnorm(0, 5),
        sigma ~ dexp(1),
        sigma_ab ~ dexp(1),
        L_Omega ~ dlkjcorr(2)
      )
      """
      try cafeAlist.write(
        to: paths.preliminaries.appendingPathComponent("\(model).alist.R"),
        atomically: true, encoding: .utf8)

      // Forward: alist → original Stan.
      let original = try String(contentsOf: stancode(model: model), encoding: .utf8)

      // Reverse: Stan → emitted alist.
      _ = try stan2alist(model: model, force: true)

      // Verify the emitted alist contains no `'` (T4 emitter fix).
      let emittedAlist = try String(
        contentsOf: paths.preliminaries.appendingPathComponent("\(model).alist.R"),
        encoding: .utf8)
      #expect(!emittedAlist.contains("'"),
              "emitted alist must not contain `'`:\n\(emittedAlist)")

      // Forward again: emitted alist → Stan (must equal the original).
      let roundtrip = try String(contentsOf: stancode(model: model), encoding: .utf8)
      #expect(roundtrip == original,
              "alist-text round-trip diverged:\n--- original ---\n\(original)\n--- roundtrip ---\n\(roundtrip)")
    }
  }
}
