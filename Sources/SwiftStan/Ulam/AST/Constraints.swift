//
//  Constraints.swift
//  SwiftStan
//
//  2026-06-03: declaration-only `<lower=…, upper=…>` constraints on a
//  parameter, paired with `Prior` / `VaryingPrior`. Same shape as
//  `Truncation` but conceptually distinct: `Truncation` drives both
//  the parameter declaration AND a `T[lo, hi]` sampling suffix; the
//  sampling suffix is redundant noise when the prior's support is
//  already the constraint (e.g. `.exponential` on lower=0, `.beta` on
//  (0, 1)). `Constraints` gives users the declaration side without
//  the sampling-line `T[…]`.
//
//  Use the static `.none` constant where you want the default.
//

import Foundation

public struct Constraints: Hashable, Sendable {
  public let lower: DistributionArg?
  public let upper: DistributionArg?

  public init(lower: DistributionArg? = nil, upper: DistributionArg? = nil) {
    self.lower = lower
    self.upper = upper
  }

  public static let none = Constraints()

  public var isEmpty: Bool { lower == nil && upper == nil }

  /// Translate to a `Truncation` for internal use by `DataInference` —
  /// the classify pass merges constraint values into the same
  /// `parameterTruncationByName` dict the declaration-constraint
  /// renderer reads from. The statement-level `truncation:` field is
  /// what drives sampling-line `T[…]` emission, so leaving it as
  /// `.none` while populating the dict via `Constraints` gives us the
  /// declaration-only emission.
  internal var asTruncation: Truncation {
    Truncation(lower: lower, upper: upper)
  }
}
