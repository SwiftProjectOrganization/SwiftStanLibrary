//
//  StanProgram.swift
//  Stan
//
//  Slice B of Docs/Stan2AlistCommandPlan.md — the value types produced
//  by `StanBlockParser`. A `StanProgram` is a structural, lossless-enough
//  view of the subset of Stan that `stancode` emits plus the idiomatic
//  hand-written shapes seen in the wild (e.g. radon_pp.stan): block
//  declarations with their type + constraints, model-block sampling and
//  assignment statements, and the names of any blocks parsed-and-dropped
//  (so Slice C can warn about them).
//
//  Distribution-argument and RHS expression *meaning* is not interpreted
//  here — args stay as source-string slices for Slice C to reconstruct
//  via the reverse `DistributionCatalog`.
//

import Foundation

/// A declared symbol in a `data` or `parameters` block, with its parsed
/// type and any `<...>` constraints.
struct StanDecl: Equatable {
  let name: String
  let type: StanType
  let constraints: StanConstraints
  /// The original (comment-stripped, whitespace-collapsed) declaration
  /// text, kept for diagnostics.
  let raw: String
}

/// The Stan type of a declaration, restricted to the shapes the reverse
/// pipeline understands. `other` preserves the raw spec for an
/// unrecognised type so Slice C can decide whether to drop or reject it.
enum StanType: Equatable {
  case real
  case int
  /// `vector[<size>]` — `size` is a cardinality symbol (e.g. `N`, `N_county`).
  case vector(size: String)
  /// `array[<size>] int`
  case arrayInt(size: String)
  /// `array[<size>] real`
  case arrayReal(size: String)
  /// `array[<outer>] vector[<length>]` — varying-vector parameter shape.
  case arrayVector(outer: String, length: String)
  /// `matrix[<rows>, <cols>]`
  case matrix(rows: String, cols: String)
  /// `cov_matrix[<dim>]`
  case covMatrix(dim: String)
  /// `cholesky_factor_corr[<dim>]`
  case cholFactorCorr(dim: String)
  /// Any spec we don't model yet — kept verbatim.
  case other(String)
}

/// Parsed contents of a declaration's `<...>` constraint block. All four
/// slots stay as source strings (`"0"`, `"N_county"`, `"mu_alpha"`) so
/// Slice C can map them back to literals / symbols itself.
struct StanConstraints: Equatable {
  var lower: String?
  var upper: String?
  var offset: String?
  var multiplier: String?

  static let none = StanConstraints()
  var isEmpty: Bool { lower == nil && upper == nil && offset == nil && multiplier == nil }
}

/// `T[lower, upper]` truncation suffix on a sampling statement. Either
/// bound may be absent (one-sided truncation renders as `T[0, ]`).
struct StanTruncation: Equatable {
  var lower: String?
  var upper: String?
}

/// A single statement inside the `model` block.
enum StanModelStatement: Equatable {
  /// `<lhs> ~ <distName>(<args>) [T[...]];` — `args` are top-level
  /// comma-split source slices, uninterpreted.
  case sampling(lhs: String,
                distName: String,
                args: [String],
                truncation: StanTruncation?)
  /// `<lhs> = <rhs>;` — `rhs` kept as a raw source string.
  case assignment(lhs: String, rhs: String)
}

/// Structured view of a parsed `.stan` program.
struct StanProgram: Equatable {
  var dataDecls: [StanDecl]
  var parameterDecls: [StanDecl]
  var modelStatements: [StanModelStatement]
  /// Assignment statements from the `generated quantities` block, if any.
  /// Each entry is `.assignment(lhs: "<type>[N] <name>", rhs: "<dist>_rng(<args>)")`.
  /// `StanToUlamModel` maps these to `Statement.generatedQuantity`; `AlistTextEmitter`
  /// renders them as `<name> <- sim(d*(<args>))`.
  var gqStatements: [StanModelStatement]
  /// Names of blocks that were recognised but intentionally not
  /// translated (`transformed parameters`, `transformed data`, `functions`).
  /// Slice C surfaces these as loud warnings.
  var droppedBlocks: [String]
}

enum StanBlockParseError: Error, CustomStringConvertible {
  case unrecognizedTopLevel(String)
  case unterminatedBlock(String)
  case malformedDeclaration(String)
  case malformedModelStatement(String)
  case unsupportedLoop

  var description: String {
    switch self {
    case .unrecognizedTopLevel(let s):
      return "stan2alist: unrecognized top-level construct near \"\(s)\""
    case .unterminatedBlock(let s):
      return "stan2alist: block '\(s)' is missing its closing brace"
    case .malformedDeclaration(let s):
      return "stan2alist: could not parse declaration \"\(s)\""
    case .malformedModelStatement(let s):
      return "stan2alist: could not parse model statement \"\(s)\""
    case .unsupportedLoop:
      return "stan2alist: model block contains a `for`/`while` loop — looped linear models (non-vectorisable indexed RHS) are out of v1 scope"
    }
  }
}
