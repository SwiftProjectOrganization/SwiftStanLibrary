//
//  LinkFunction.swift
//  Stan
//
//  Phase 1 of the ulam port: link function catalog.
//
//  In ulam syntax `logit(p) <- a + b*x` means "the logit of p equals the
//  linear predictor", which in Stan is written `p = inv_logit(a + b*x)`.
//  The generator emits the inverse, so case names follow ulam (the link),
//  not the Stan emission (the inverse-link).
//

import Foundation

public enum LinkFunction: Hashable, Sendable {
  case logit
  case log
  case invLogit
}
