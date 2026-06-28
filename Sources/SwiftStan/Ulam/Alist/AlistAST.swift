//
//  AlistAST.swift
//  Stan
//
//  Slice A of the alist parser: parsed shapes of R `alist(...)` source.
//  Internal — only the alist lowering / emission pipeline consumes
//  these. See `Docs/AlistParser.md` for the staged plan.
//
//  Each `AlistStatement` is one comma-separated entry in the alist
//  body. Semantic interpretation (likelihood vs prior, distribution
//  catalog mapping, σ-slot truncation inference) happens later in
//  slices B–D — the parser only captures the source shape.
//

import Foundation

internal indirect enum AlistStatement: Equatable {
  /// `<lhs> ~ <dist>(args) [T[lo, hi]]`
  case sample(lhs: AlistSampleLhs,
              dist: AlistDistribution,
              truncation: Truncation)
  /// `<link>(<target>) <- <rhs>` — e.g. `logit(p) <- a + b*x`.
  case link(function: AlistLink,
            target: String,
            rhs: ExpressionNode)
  /// `<target> <- sim(<dist>(args))` — McElreath-style posterior-predictive
  /// draw. Lowered to `Statement.generatedQuantity` and emitted into the
  /// Stan `generated quantities` block as `<type>[N] <target> = <dist>_rng(args);`.
  case generatedQuantity(target: String, dist: AlistDistribution)
}

/// LHS of a `~` statement. Four shapes show up in McElreath's alists:
internal enum AlistSampleLhs: Equatable {
  /// `pulled_left` or `sigma_actor` — a plain identifier.
  case scalar(String)
  /// `a_actor[actor]` — varying intercept / slope.
  case indexed(name: String, indexColumn: String)
  /// `c(a, bp, bpc)` — group-prior shorthand, expanded by Slice B.
  case group([String])
  /// `c(a, b)[cafe]` — Chapter-14 correlated varying effects. Lowering
  /// synthesises a single packed parameter name by concatenation
  /// (`["a", "b"]` → `ab`) and records `length = names.count`.
  case groupIndexed(names: [String], indexColumn: String)
}

internal enum AlistLink: String, Equatable {
  case logit
  case log
  case cloglog
  /// `f(p) <- expr` with `f` not one of the recognised links is treated
  /// as identity (deterministic assignment). Slice E maps this to
  /// `Deterministic` rather than `Link`.
  case identity
}

internal struct AlistDistribution: Equatable {
  /// R-side name: `dnorm`, `dbinom`, `dcauchy`, etc. Slice B maps to
  /// the V1 `Distribution` catalog.
  internal let name: String
  internal let args: [ExpressionNode]
}
