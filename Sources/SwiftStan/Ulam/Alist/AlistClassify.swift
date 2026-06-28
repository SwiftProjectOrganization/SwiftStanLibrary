//
//  AlistClassify.swift
//  Stan
//
//  Slices C + D of the alist parser.
//
//  Slice C: walks the lowered statements and assigns every identifier
//  to one of five roles —
//    - outcome (LHS of the first scalar sample, by McElreath convention)
//    - scalarParam (other scalar sample LHSes)
//    - varyingParam (indexed sample LHSes)
//    - indexColumn (the bracketed name in a varying-sample LHS)
//    - dataColumn (everything else referenced from link RHS or
//      distribution args)
//
//  Slice D: layered on top — every scalar parameter that appears in
//  the σ slot of some `.normal` / `.cauchy` / `.lognormal` /
//  `.gamma` (scale-shape) distribution gets a `lower: 0` truncation in
//  its final declaration. This recovers McElreath's half-Cauchy /
//  half-normal conventions without explicit `T[0,]` in the alist.
//

import Foundation

internal struct ClassifiedAlist: Equatable {
  internal struct Statement: Equatable {
    internal enum Kind: Equatable {
      case likelihood
      case scalarPrior
      case varyingPrior(indexedBy: String)
      /// Promoted from `.scalarSample` when classify detects the LHS
      /// also appears as the σ-vector of a `.varyingVectorSample`'s
      /// `diag_pre_multiply(σ, L)` chol arg. `length` is the cardinality
      /// symbol (v1: hard-coded "J").
      case vectorPrior(length: String)
      /// Chapter-14 correlated varying effects: `c(a, b)[cafe] ~ dmvnormchol(...)`
      /// lowered to a packed parameter (`name = "ab"`) with `length`
      /// = `c(...)` arity, same cardinality symbol the companion
      /// `vectorPrior` uses.
      case varyingVectorPrior(indexedBy: String, length: String)
      /// `L_Omega ~ dlkjcorr(eta)` lowered through `.lkjCorrCholesky`,
      /// classified directly as the matching DSL prior. `dim` is the
      /// shared cardinality symbol (v1: "J") supplied by the companion
      /// `.varyingVectorSample`; without one the classify pass falls
      /// back to "J" and the user must supply it via data.
      case lkjCorrCholeskyPrior(dim: String)
      case link(LinkFunction)
      /// Bare `<name> <- <rhs>` — McElreath's deterministic
      /// assignment line. Stored with `linkRhs` carrying the RHS
      /// expression so emitter passes can reuse the same canonicalised
      /// source path as `.link`.
      case deterministic
      /// `<name> <- sim(<dist>)` — posterior-predictive draw emitted into
      /// the Stan `generated quantities` block. The output symbol is neither
      /// data nor parameter; it must not appear in `dataColumns`.
      case generatedQuantity
    }
    internal let kind: Kind
    internal let name: String          // outcome / param / link target
    internal let dist: Distribution?   // nil for links
    internal let truncation: Truncation
    /// Declaration-only `<lower, upper>` constraints inferred from a
    /// bounded-support prior (e.g. `dbeta` → (0, 1)). Distinct from
    /// `truncation`: this never emits a sampling-line `T[…]` suffix.
    internal let constraints: Constraints
    internal let linkRhs: ExpressionNode?  // non-nil only for links

    internal init(kind: Kind,
                  name: String,
                  dist: Distribution?,
                  truncation: Truncation,
                  constraints: Constraints = .none,
                  linkRhs: ExpressionNode?) {
      self.kind = kind
      self.name = name
      self.dist = dist
      self.truncation = truncation
      self.constraints = constraints
      self.linkRhs = linkRhs
    }
  }

  internal let statements: [Statement]
  internal let outcome: String
  internal let scalarParams: [String]
  internal let varyingParams: [String]
  /// σ-vector parameters promoted from scalar (e.g. `sigma_ab` from
  /// `sigma_ab ~ dexp(1)` paired with `c(a,b)[cafe] ~ dmvnormchol(…, sigma_ab)`).
  internal let vectorParams: [String]
  /// Packed varying-vector parameters (e.g. `ab` from `c(a, b)[cafe]`).
  internal let varyingVectorParams: [String]
  /// `lengthSymbol → integer length` bindings synthesised by classify
  /// from the LHS `c(...)` arity. v1 hard-codes the symbol as "J".
  internal let lengthBindings: [String: Int]
  internal let indexColumns: [String]
  internal let dataColumns: [String]
}

internal enum AlistClassifyError: Error, CustomStringConvertible {
  case noLikelihood

  internal var description: String {
    switch self {
    case .noLikelihood:
      return "AlistClassify: alist has no `~`-shaped likelihood statement"
    }
  }
}

internal enum AlistClassify {
  /// v1 cardinality symbol used by every `.varyingVectorSample` and the
  /// promoted σ-vector(s) it implies. Multi-grouping models with
  /// distinct vector lengths aren't supported yet — they would collide
  /// on this single symbol.
  private static let varyingVectorLengthSymbol = "J"

  internal static func classify(_ lowered: [LoweredAlistStatement]) throws -> ClassifiedAlist {
    // Pre-pass: collect σ-vector promotion targets and the J length
    // binding from any `.varyingVectorSample` statements. The σ-name is
    // captured at lowering time so we don't have to re-parse the
    // diag_pre_multiply chol arg here.
    var vectorPromotions: [String: String] = [:]   // sigmaName → "J"
    var lengthBindings: [String: Int] = [:]        // "J" → 2
    var halfPositive: Set<String> = []
    // `c(a, b)[cafe] ~ dmvnorm2(...)` packs its split coefficients into a
    // single `array[N] vector[J]` parameter (`name`), so a deterministic
    // line that still references the split names (`a[cafe]`, `b[cafe]`)
    // must be rewritten to the packed-and-indexed form
    // (`name[cafe][1]`, `name[cafe][2]`). Map each component to (packed
    // name, 1-based slot).
    var componentSlots: [String: (packed: String, slot: Int)] = [:]
    for stmt in lowered {
      if case .varyingVectorSample(let name, _, let len, let components, let sName, _, _) = stmt {
        vectorPromotions[sName] = varyingVectorLengthSymbol
        lengthBindings[varyingVectorLengthSymbol] = len
        // σ-vectors flanking a Cholesky scale are conventionally
        // positive; promote them into the half-positive set the
        // truncation post-pass already consults.
        halfPositive.insert(sName)
        for (i, comp) in components.enumerated() {
          componentSlots[comp] = (packed: name, slot: i + 1)
        }
      }
    }

    // McElreath convention: the first `~` statement (whose LHS is a
    // plain identifier, i.e. scalarSample) is the likelihood. Every
    // subsequent scalar sample is a prior on a parameter.
    var outcome: String? = nil
    var scalarParams: [String] = []
    var varyingParams: [String] = []
    var vectorParams: [String] = []
    var varyingVectorParams: [String] = []
    var indexColumns: [String] = []
    var statements: [ClassifiedAlist.Statement] = []
    var generatedQuantityNames: [String] = []
    var seenScalar = false

    for stmt in lowered {
      switch stmt {
      case .scalarSample(let name, let dist, let trunc):
        if !seenScalar {
          outcome = name
          seenScalar = true
          statements.append(.init(kind: .likelihood,
                                  name: name,
                                  dist: dist,
                                  truncation: trunc,
                                  linkRhs: nil))
        } else if let lengthSym = vectorPromotions[name] {
          vectorParams.append(name)
          statements.append(.init(kind: .vectorPrior(length: lengthSym),
                                  name: name,
                                  dist: dist,
                                  truncation: trunc,
                                  linkRhs: nil))
        } else if case .lkjCorrCholesky = dist {
          // dlkjcorr lowers to `.lkjCorrCholesky`; promote to the
          // dedicated DSL prior with `dim` taken from the same
          // cardinality symbol the companion varying-vector uses.
          // Track as a vector param so it isn't double-counted as a
          // scalar (the generator allocates `cholesky_factor_corr[J]`).
          vectorParams.append(name)
          statements.append(.init(
            kind: .lkjCorrCholeskyPrior(dim: varyingVectorLengthSymbol),
            name: name,
            dist: dist,
            truncation: trunc,
            linkRhs: nil))
        } else {
          scalarParams.append(name)
          statements.append(.init(kind: .scalarPrior,
                                  name: name,
                                  dist: dist,
                                  truncation: trunc,
                                  linkRhs: nil))
        }
      case .varyingSample(let name, let idx, let dist, let trunc):
        varyingParams.append(name)
        indexColumns.append(idx)
        statements.append(.init(kind: .varyingPrior(indexedBy: idx),
                                name: name,
                                dist: dist,
                                truncation: trunc,
                                linkRhs: nil))
      case .varyingVectorSample(let name, let idx, _, _, _, let dist, let trunc):
        varyingVectorParams.append(name)
        indexColumns.append(idx)
        statements.append(.init(
          kind: .varyingVectorPrior(indexedBy: idx,
                                    length: varyingVectorLengthSymbol),
          name: name,
          dist: dist,
          truncation: trunc,
          linkRhs: nil))
      case .link(let fn, let target, let rhs):
        statements.append(.init(kind: .link(fn),
                                name: target,
                                dist: nil,
                                truncation: .none,
                                linkRhs: rewritePackedComponents(rhs, using: componentSlots)))
      case .deterministic(let target, let rhs):
        statements.append(.init(kind: .deterministic,
                                name: target,
                                dist: nil,
                                truncation: .none,
                                linkRhs: rewritePackedComponents(rhs, using: componentSlots)))
      case .generatedQuantity(let name, let dist):
        generatedQuantityNames.append(name)
        statements.append(.init(kind: .generatedQuantity,
                                name: name,
                                dist: dist,
                                truncation: .none,
                                linkRhs: nil))
      }
    }

    guard let outcomeName = outcome else {
      throw AlistClassifyError.noLikelihood
    }

    // Data columns = every other identifier referenced anywhere in
    // link RHSes or distribution args, minus the names we already
    // know are outcomes/parameters/index columns.
    var known: Set<String> = [outcomeName]
    known.formUnion(scalarParams)
    known.formUnion(varyingParams)
    known.formUnion(vectorParams)
    known.formUnion(varyingVectorParams)
    known.formUnion(indexColumns)
    // The synthesised cardinality symbols (e.g. "J") aren't user data.
    known.formUnion(lengthBindings.keys)
    // Generated-quantity outputs are neither data nor parameters — exclude
    // them so they don't appear in `dataColumns` and end up as CSV inputs.
    known.formUnion(generatedQuantityNames)
    var referenced: Set<String> = []
    for stmt in statements {
      if let dist = stmt.dist {
        for arg in distributionSymbols(dist) {
          referenced.insert(arg)
        }
      }
      if let rhs = stmt.linkRhs {
        for ref in rhs.symbolReferences() {
          referenced.insert(ref.name)
        }
      }
    }
    let dataColumns = referenced.subtracting(known).sorted()

    // Slice D: σ-slot truncation inference. Walk every distribution
    // and collect names that appear as the *last* positional arg of
    // a normal / cauchy / lognormal / gamma — these are scale
    // parameters and conventionally non-negative. Augmented above
    // with σ-vector names from `.varyingVectorSample`.
    for stmt in statements {
      guard let dist = stmt.dist else { continue }
      if let scaleArg = scaleArgIfApplicable(dist),
         case .symbol(let scaleName) = scaleArg {
        halfPositive.insert(scaleName)
      }
    }
    let adjusted = statements.map { s -> ClassifiedAlist.Statement in
      let isScalarPrior: Bool = {
        if case .scalarPrior = s.kind { return true }
        return false
      }()
      let promotable: Bool = isScalarPrior || {
        if case .vectorPrior = s.kind { return true }
        return false
      }()
      // Natural-support inference: a scalar parameter with a
      // bounded-support prior (e.g. `dbeta` on (0, 1)) gets the matching
      // declaration constraint. Uses `Constraints` (declaration-only) so
      // no redundant `T[…]` suffix lands on the sampling statement.
      let constraints = isScalarPrior ? naturalSupportConstraints(s.dist) : .none
      // Slice D: merge `lower: 0` into a σ-scale parameter's truncation —
      // but only when the prior didn't already impose declaration
      // constraints. A parameter that both sits in a normal's σ-slot and
      // carries a bounded-support prior (e.g. `sigma ~ dunif(0, 50)` in
      // McElreath's Howell m4.1) would otherwise get BOTH `truncation:`
      // and `constraints:` set, which the generator rejects. The
      // constraint's lower bound already subsumes the scale-positivity
      // truncation, so the redundant truncation is dropped.
      let trunc = (promotable && halfPositive.contains(s.name) && constraints.isEmpty)
        ? mergeLowerZero(s.truncation)
        : s.truncation
      if trunc != s.truncation || !constraints.isEmpty {
        return .init(kind: s.kind,
                     name: s.name,
                     dist: s.dist,
                     truncation: trunc,
                     constraints: constraints,
                     linkRhs: s.linkRhs)
      }
      return s
    }

    return ClassifiedAlist(
      statements: adjusted,
      outcome: outcomeName,
      scalarParams: scalarParams,
      varyingParams: varyingParams,
      vectorParams: vectorParams,
      varyingVectorParams: varyingVectorParams,
      lengthBindings: lengthBindings,
      indexColumns: indexColumns.uniqued(),
      dataColumns: dataColumns)
  }

  // MARK: - Helpers

  /// 2026-06-08: delegate entirely to
  /// `DistributionCatalog.symbolsReferenced(_:)`. That helper expands
  /// `.expression(String)` arguments via the shared identifier
  /// tokeniser (for compound dist-arg slots like `dnorm(alpha[county]
  /// + beta*floor, sigma)`), so the alist pipeline's referenced-symbol
  /// set picks up the embedded identifiers the same way `DataInference`
  /// does. The pre-2026-06-08 handwritten per-case walk only ran `sym`
  /// against `.symbol` args and silently dropped `.expression` —
  /// turning compound mu args into "undeclared symbol" errors at the
  /// generate stage.
  private static func distributionSymbols(_ d: Distribution) -> [String] {
    return DistributionCatalog.symbolsReferenced(d)
  }

  /// The σ / scale arg for distributions where it makes sense to
  /// infer `lower: 0`. Returns nil for distributions without a
  /// well-defined positive-scale slot.
  private static func scaleArgIfApplicable(_ d: Distribution) -> DistributionArg? {
    switch d {
    case .normal(_, let sigma):     return sigma
    case .cauchy(_, let sigma):     return sigma
    case .lognormal(_, let sigma):  return sigma
    case .studentT(_, _, let sigma): return sigma
    case .gamma(_, let rate):       return rate
    // multivariateNormal's σ is a covariance matrix — handled by V1
    // outside the lower:0 path.
    default:                        return nil
    }
  }

  /// Declaration constraints implied by a prior's natural support.
  /// `dbeta` is bounded to (0, 1); `dunif(a, b)` to its own (a, b) — a
  /// uniform prior is improper unless the parameter is declared on the
  /// same interval. Other distributions add nothing here (scale
  /// positivity is handled separately via Slice D truncation).
  private static func naturalSupportConstraints(_ d: Distribution?) -> Constraints {
    guard let d else { return .none }
    switch d {
    case .beta:
      return Constraints(lower: 0, upper: 1)
    case .uniform(let lower, let upper):
      return Constraints(lower: lower, upper: upper)
    default:
      return .none
    }
  }

  private static func mergeLowerZero(_ trunc: Truncation) -> Truncation {
    if trunc.lower != nil { return trunc }
    return Truncation(lower: 0, upper: trunc.upper)
  }

  /// Rewrite references to a `c(...)`-packed coefficient's split name in
  /// a deterministic / link RHS into the packed-and-indexed form. With
  /// `c(a, b)[cafe] ~ dmvnorm2(...)` packed as `ab`, the line
  /// `mu <- a[cafe] + b[cafe]*x` becomes `ab[cafe][1] + ab[cafe][2]*x`
  /// — the only shape the generator can emit (an `array[N] vector[J]`
  /// element access). Non-component symbols pass through untouched.
  private static func rewritePackedComponents(
    _ node: ExpressionNode,
    using slots: [String: (packed: String, slot: Int)]) -> ExpressionNode {
    if slots.isEmpty { return node }
    func walk(_ n: ExpressionNode) -> ExpressionNode {
      switch n {
      case .identifier, .literal:
        return n
      case .indexed(let name, let index):
        if let s = slots[name] {
          return .chainedIndexed(name: s.packed,
                                 outerIndex: walk(index),
                                 innerIndex: .literal(.integer(s.slot)))
        }
        return .indexed(name: name, index: walk(index))
      case .binary(let op, let lhs, let rhs):
        return .binary(op: op, lhs: walk(lhs), rhs: walk(rhs))
      case .unary(let op, let operand):
        return .unary(op: op, operand: walk(operand))
      case .call(let name, let argument):
        return .call(name: name, argument: walk(argument))
      case .chainedIndexed(let name, let outer, let inner):
        return .chainedIndexed(name: name, outerIndex: walk(outer), innerIndex: walk(inner))
      case .subscript2(let name, let idx1, let idx2):
        return .subscript2(name: name, idx1: walk(idx1), idx2: walk(idx2))
      }
    }
    return walk(node)
  }
}

private extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen: Set<Element> = []
    var out: [Element] = []
    for x in self where seen.insert(x).inserted { out.append(x) }
    return out
  }
}

// MARK: - Stub-data heuristic (shared by AlistEmitter + AlistToUlamModel)
//
// Per Docs/AlistParser.md Q1(b): integer columns are likelihood
// outcomes of bernoulli/binomial/poisson and any column used as a
// `[col]` index; everything else is real. The actual values come
// from the CSV downstream (csv2json).

internal enum StubDataKind: Equatable {
  case integer
  case real
}

extension ClassifiedAlist {
  internal func stubKind(for column: String) -> StubDataKind {
    if indexColumns.contains(column) { return .integer }
    if column == outcome,
       let likelihood = statements.first(where: { $0.kind == .likelihood }),
       let dist = likelihood.dist,
       Self.isIntegerOutcome(dist) {
      return .integer
    }
    // Stan requires the binomial trials count to be an integer array
    // (`binomial(trials, theta)` rejects a `vector[N] trials`). A data
    // column that fills the `n` slot of any binomial is therefore typed
    // as integer, mirroring the outcome heuristic above.
    if isBinomialTrialsCount(column) { return .integer }
    return .real
  }

  /// True when `column` appears (as a bare symbol) in the trials slot
  /// of any binomial distribution in the model.
  private func isBinomialTrialsCount(_ column: String) -> Bool {
    for stmt in statements {
      guard case .binomial(let n, _)? = stmt.dist else { continue }
      if case .symbol(let s) = n, s == column { return true }
    }
    return false
  }

  private static func isIntegerOutcome(_ d: Distribution) -> Bool {
    switch d {
    case .bernoulli, .binomial, .poisson: return true
    default: return false
    }
  }
}
