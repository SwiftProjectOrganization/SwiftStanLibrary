//
//  Truncation.swift
//  Stan
//
//  Phase 3 of the ulam port: optional `T[lower, upper]` suffix on a
//  sampling statement. Either bound (or both) can be omitted to express
//  one-sided truncation: `T[a, ]` (lower only), `T[ , b]` (upper only).
//
//  Use the static `.none` constant on `Likelihood`/`Prior` initialisers
//  where you want the default (no truncation).
//

import Foundation

public struct Truncation: Hashable, Sendable {
  public let lower: DistributionArg?
  public let upper: DistributionArg?

  public init(lower: DistributionArg? = nil, upper: DistributionArg? = nil) {
    self.lower = lower
    self.upper = upper
  }

  public static let none = Truncation()

  public var isEmpty: Bool { lower == nil && upper == nil }
}
