//
//  UlamData.swift
//  Stan
//
//  Phase 1 of the ulam port: the input-data abstraction. Stan's type
//  system distinguishes `int` from `real` (R does not), so the column
//  enum carries the tag explicitly.
//

import Foundation

public enum UlamColumn: Hashable, Sendable {
  case real([Double])
  case integer([Int])
  case scalarReal(Double)
  case scalarInt(Int)
  // Phase 6 — matrix-flavoured data shapes.
  /// `vector[<countSymbol>] <name>;` — a fixed-length real vector.
  case realVector(length: Int, values: [Double])
  /// `cov_matrix[<countSymbol>] <name>;` — a K×K symmetric positive-
  /// definite matrix.
  case realCovMatrix(dim: Int, values: [[Double]])
  /// `array[N] vector[<countSymbol>] <name>;` — an N-row outer array of
  /// K-length real vectors.
  case realArrayVector(rowCount: Int, colCount: Int, values: [[Double]])
  /// SUR Slice C — `matrix[N, <cols>] <name>;`. An N-row × J-column
  /// real matrix, used as a multi-outcome dependent variable
  /// (`matrix[N, J] y;`) or a stacked predictor matrix
  /// (`matrix[N, K] x;`) in Seemingly Unrelated Regressions. Stan's
  /// `matrix` declaration takes both dimensions explicitly, so v1
  /// emits the column count as a literal — the model block keeps
  /// using the `K`/`J` cardinality symbols declared by
  /// `MatrixPrior` / `CovMatrixPrior`, and the user passes those as
  /// scalar-int data so cmdstan keeps row/parameter shapes
  /// consistent at JSON-load time.
  case realMatrix(rows: Int, cols: Int, values: [[Double]])
}

extension UlamColumn {
  /// True for any shape whose outer dimension contributes to the
  /// implicit `N` row count. `.realVector` and `.realCovMatrix` are
  /// fixed-shape and *don't* drive `N`; `.realArrayVector`'s outer
  /// dimension *is* `N`.
  public var isVector: Bool {
    switch self {
    case .real, .integer, .realArrayVector, .realMatrix: return true
    case .scalarReal, .scalarInt, .realVector, .realCovMatrix: return false
    }
  }

  /// Row count contribution to `N`. Nil for shapes that don't drive `N`.
  public var count: Int? {
    switch self {
    case .real(let v): return v.count
    case .integer(let v): return v.count
    case .realArrayVector(let rows, _, _): return rows
    case .realMatrix(let rows, _, _): return rows
    case .scalarReal, .scalarInt, .realVector, .realCovMatrix: return nil
    }
  }

  public var isInteger: Bool {
    switch self {
    case .integer, .scalarInt: return true
    case .real, .scalarReal, .realVector, .realCovMatrix, .realArrayVector, .realMatrix:
      return false
    }
  }

  /// Inner-vector length for shapes that carry one (Phase 6). Used to
  /// bind a cardinality symbol to its numeric size. SUR's `.realMatrix`
  /// deliberately returns nil here — its column dimension is emitted
  /// as a literal in the data block (the model block uses scalar-int
  /// symbols), so it doesn't participate in the Phase 6 single-symbol
  /// binding pass.
  public var innerLength: Int? {
    switch self {
    case .realVector(let length, _): return length
    case .realCovMatrix(let dim, _): return dim
    case .realArrayVector(_, let colCount, _): return colCount
    case .real, .integer, .scalarReal, .scalarInt, .realMatrix: return nil
    }
  }
}

public typealias UlamData = [String: UlamColumn]
