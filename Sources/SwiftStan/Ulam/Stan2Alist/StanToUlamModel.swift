//
//  StanToUlamModel.swift
//  Stan
//
//  Slice C of Docs/Stan2AlistCommandPlan.md — reverse of
//  `AlistToUlamModel` + `DataInference`. Takes a parsed `StanProgram`
//  and reconstructs the canonical `[Statement]` list that the alist
//  emitter (Slice D) renders back to McElreath `alist()` syntax.
//
//  Role inference leans on Stan's block structure, which already
//  separates data from parameters — the hard part the forward
//  `DataInference` had to *infer*:
//    - likelihood   = the `~` line whose LHS is a (non-index) data vector
//    - varyingPrior = the `~` line whose LHS is a vector parameter whose
//                     size symbol matches an index column's `upper` bound
//    - prior        = the `~` line whose LHS is a scalar parameter
//    - link/det     = `lhs = inv_logit(rhs)` / `lhs = exp(rhs)` / `lhs = rhs`
//
//  Deliberately lossy, per the v1 plan:
//    - Declaration `<lower=…, upper=…>` constraints are DROPPED. They are
//      re-derived on the forward pass by `AlistClassify` (σ-slot
//      positivity, bounded-support priors). A constraint with no such
//      source isn't representable in alist text and is simply dropped.
//    - `<offset=…, multiplier=…>` affine non-centering is stripped — the
//      reconstructed varying prior is centred (semantically identical).
//    - `generated quantities` / `transformed *` blocks were already
//      dropped by the parser; we surface them here as warnings.
//

import Foundation

enum StanToUlamError: Error, CustomStringConvertible {
  case noLikelihood
  case multipleLikelihoods([String])
  case unsupportedDeclaration(String)
  case unsupportedModelStatement(String)

  var description: String {
    switch self {
    case .noLikelihood:
      return "stan2alist: no likelihood found (no `~` statement over a data variable)"
    case .multipleLikelihoods(let names):
      return "stan2alist: multiple likelihood candidates \(names) — v1 supports a single outcome"
    case .unsupportedDeclaration(let s):
      return "stan2alist: unsupported declaration \"\(s)\""
    case .unsupportedModelStatement(let s):
      return "stan2alist: unsupported model statement — \(s)"
    }
  }
}

enum StanToUlamModel {

  struct Result {
    let statements: [Statement]
    /// Non-fatal notes (dropped blocks, etc.) surfaced to the user.
    let warnings: [String]
  }

  static func build(_ program: StanProgram) throws -> Result {
    var warnings: [String] = []
    for block in program.droppedBlocks {
      warnings.append("dropped Stan block '\(block)' — no alist representation; not translated")
    }

    // MARK: Classify data declarations.
    var dataVectorNames: Set<String> = []
    var indexColumnNames: Set<String> = []
    var columnByCardinality: [String: String] = [:]   // size symbol → index column
    for decl in program.dataDecls {
      switch decl.type {
      case .int, .real:
        // Scalar — a cardinality symbol (`N`, `N_x`) or a scalar data
        // value. Neither contributes a statement; consumed silently.
        continue
      case .vector, .arrayReal:
        dataVectorNames.insert(decl.name)
      case .arrayInt:
        dataVectorNames.insert(decl.name)
        // An integer per-row column whose `upper` bound is a symbol is a
        // group-index column (`array[N] int<lower=1, upper=N_county> county`).
        if let upper = decl.constraints.upper, isSymbol(upper) {
          indexColumnNames.insert(decl.name)
          columnByCardinality[upper] = decl.name
        }
      case .matrix:
        // Matrix data columns are tracked separately for multivariate
        // likelihood recognition; they don't enter dataVectorNames.
        break
      case .arrayVector, .cholFactorCorr, .covMatrix:
        // These types only appear in parameters, never in data — silently
        // skip if encountered (defensive; the parser shouldn't produce them
        // for data declarations in practice).
        break
      case .other(let spec):
        throw StanToUlamError.unsupportedDeclaration("\(spec) \(decl.name)")
      }
    }

    // MARK: Classify parameter declarations.
    var scalarParams: Set<String> = []
    var vectorParamSize: [String: String] = [:]           // name → size symbol
    var cholFactorDim: [String: String] = [:]             // name → K
    var arrayVectorShape: [String: (outer: String, length: String)] = [:]
    var covMatrixDim: [String: String] = [:]              // name → dim
    var matrixShape: [String: (rows: String, cols: String)] = [:]
    // Data columns whose declaration type is matrix — used by role
    // inference to distinguish a matrix data column (likelihood target)
    // from a matrix parameter.
    var matrixDataColumns: Set<String> = []
    for decl in program.parameterDecls {
      switch decl.type {
      case .real, .int:
        scalarParams.insert(decl.name)
      case .vector(let size):
        vectorParamSize[decl.name] = size
      case .arrayVector(let outer, let length):
        arrayVectorShape[decl.name] = (outer: outer, length: length)
      case .cholFactorCorr(let dim):
        cholFactorDim[decl.name] = dim
      case .covMatrix(let dim):
        covMatrixDim[decl.name] = dim
      case .matrix(let rows, let cols):
        matrixShape[decl.name] = (rows: rows, cols: cols)
      case .arrayInt, .arrayReal, .other:
        throw StanToUlamError.unsupportedDeclaration(decl.raw)
      }
    }
    for decl in program.dataDecls {
      if case .matrix = decl.type { matrixDataColumns.insert(decl.name) }
    }

    // MARK: Walk the model block.
    var likelihoods: [Statement] = []
    var links: [Statement] = []
    // Priors keyed by parameter name so we can re-order by declaration
    // order after the model walk. Order matters: `parametersBlock` iterates
    // `inferred.parameters` which follows statement list order.
    var priorByName: [String: Statement] = [:]

    for stmt in program.modelStatements {
      switch stmt {
      case let .assignment(lhs, rhs):
        links.append(reconstructAssignment(lhs: lhs, rhs: rhs))

      case let .sampling(lhs, distName, args, trunc):
        // `to_vector(<matrix>)` LHS — matrix prior (iid via to_vector).
        // Peel the function call and look up the matrix parameter.
        let effectiveLhs: String
        var toVectorMatrixName: String? = nil
        if lhs.hasPrefix("to_vector("), lhs.hasSuffix(")") {
          let inner = String(lhs.dropFirst("to_vector(".count).dropLast())
            .trimmingCharacters(in: .whitespaces)
          toVectorMatrixName = inner
          effectiveLhs = inner
        } else {
          effectiveLhs = lhs
        }

        let dist = try DistributionCatalog.distribution(fromStanName: distName, args: args)
        let truncation = toTruncation(trunc)

        if let matName = toVectorMatrixName, let shape = matrixShape[matName] {
          priorByName[matName] = .matrixPrior(name: matName,
                                              rows: shape.rows,
                                              cols: shape.cols,
                                              distribution: dist,
                                              truncation: truncation,
                                              useLpdf: false)
        } else if matrixDataColumns.contains(effectiveLhs) {
          // Matrix data column → multivariate likelihood (SUR outcome).
          likelihoods.append(.likelihood(lhs: effectiveLhs,
                                          distribution: dist,
                                          truncation: truncation,
                                          useLpdf: false))
        } else if dataVectorNames.contains(effectiveLhs)
                    && !indexColumnNames.contains(effectiveLhs) {
          likelihoods.append(.likelihood(lhs: effectiveLhs,
                                         distribution: dist,
                                         truncation: truncation,
                                         useLpdf: false))
        } else if scalarParams.contains(effectiveLhs) {
          priorByName[effectiveLhs] = .prior(name: effectiveLhs,
                                             distribution: dist,
                                             truncation: truncation,
                                             constraints: .none,
                                             start: nil,
                                             useLpdf: false)
        } else if let dim = cholFactorDim[effectiveLhs] {
          guard case let .lkjCorrCholesky(eta) = dist else {
            throw StanToUlamError.unsupportedModelStatement(
              "cholesky_factor_corr parameter '\(effectiveLhs)' must be sampled from lkj_corr_cholesky")
          }
          priorByName[effectiveLhs] = .lkjCorrCholeskyPrior(name: effectiveLhs, dim: dim, eta: eta)
        } else if let dim = covMatrixDim[effectiveLhs] {
          guard case let .wishart(nu, V) = dist else {
            throw StanToUlamError.unsupportedModelStatement(
              "cov_matrix parameter '\(effectiveLhs)' must be sampled from wishart")
          }
          priorByName[effectiveLhs] = .wishartPrior(name: effectiveLhs, dim: dim, nu: nu, V: V)
        } else if let shape = arrayVectorShape[effectiveLhs] {
          // `array[N_g] vector[K]` parameter — varying-vector prior.
          // Pair with the index column whose cardinality matches `outer`.
          guard let indexColumn = columnByCardinality[shape.outer] else {
            throw StanToUlamError.unsupportedModelStatement(
              "array-vector parameter '\(effectiveLhs)': no data column with upper=\(shape.outer) (ambiguous or missing index column)")
          }
          priorByName[effectiveLhs] = .varyingVectorPrior(name: effectiveLhs,
                                                          indexedBy: indexColumn,
                                                          length: shape.length,
                                                          countSymbol: nil,
                                                          distribution: dist,
                                                          truncation: truncation,
                                                          useLpdf: false)
        } else if let size = vectorParamSize[effectiveLhs] {
          if let indexColumn = columnByCardinality[size] {
            priorByName[effectiveLhs] = .varyingPrior(name: effectiveLhs,
                                                      indexedBy: indexColumn,
                                                      countSymbol: nil,
                                                      distribution: dist,
                                                      truncation: truncation,
                                                      constraints: .none,
                                                      start: nil,
                                                      useLpdf: false,
                                                      nonCentered: false)
          } else {
            // Plain vector prior (e.g. sigma_ab — not indexed by a group column).
            priorByName[effectiveLhs] = .vectorPrior(name: effectiveLhs,
                                                     length: size,
                                                     distribution: dist,
                                                     truncation: truncation,
                                                     useLpdf: false)
          }
        } else {
          throw StanToUlamError.unsupportedModelStatement(
            "sampling target '\(lhs)' is neither a data outcome nor a declared parameter")
        }
      }
    }

    // Rebuild `priors` in parameter-declaration order so `parametersBlock`
    // emits declarations in the same sequence the forward emitter uses.
    // `cov_matrix` parameters have no sampling line — they are added here
    // as declaration-only `.covMatrixPrior` entries for any name not yet
    // in `priorByName`.
    var priors: [Statement] = []
    for decl in program.parameterDecls {
      let name = decl.name
      if let stmt = priorByName[name] {
        priors.append(stmt)
      } else if case let .covMatrix(dim) = decl.type {
        priors.append(.covMatrixPrior(name: name, dim: dim))
      }
      // Other declaration-only types (if any) fall through silently.
    }

    guard !likelihoods.isEmpty else { throw StanToUlamError.noLikelihood }
    guard likelihoods.count == 1 else {
      throw StanToUlamError.multipleLikelihoods(likelihoods.map(likelihoodName))
    }

    // Reconstruct generated-quantities statements from the GQ block.
    var generated_Quantities: [Statement] = []
    for stmt in program.gqStatements {
      guard case let .assignment(lhs, rhs) = stmt else { continue }
      guard let (name, dist) = reconstructGQ(lhs: lhs, rhs: rhs) else {
        warnings.append("skipped unrecognised generated quantities statement: \(lhs) = \(rhs)")
        continue
      }
      generated_Quantities.append(.generatedQuantity(name: name, distribution: dist))
    }

    // McElreath order: likelihood first (so re-classification picks the
    // outcome), then the linear model, then the priors, then GQ draws last.
    let statements = likelihoods + links + priors + generated_Quantities
    return Result(statements: statements, warnings: warnings)
  }

  /// Parse a GQ assignment `<type>[N] <name> = <dist>_rng(<args>)` into
  /// a `(name, Distribution)` pair. Returns nil for any shape we don't
  /// recognise (caller emits a warning and skips).
  private static func reconstructGQ(lhs: String,
                                    rhs: String) -> (name: String, dist: Distribution)? {
    // Extract the variable name — last identifier token in the LHS type spec.
    guard let name = lastIdentifier(in: lhs), !name.isEmpty else { return nil }
    // RHS must be `<dist>_rng(<args>)`.
    let trimmedRhs = rhs.trimmingCharacters(in: .whitespaces)
    guard let rngRange = trimmedRhs.range(of: "_rng("),
          let closeParen = trimmedRhs.lastIndex(of: ")"),
          closeParen == trimmedRhs.index(before: trimmedRhs.endIndex) else {
      return nil
    }
    let distName = String(trimmedRhs[..<rngRange.lowerBound])
    let argsStr  = String(trimmedRhs[rngRange.upperBound..<closeParen])
    let args     = splitTopLevelCommas(argsStr)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    guard let dist = try? DistributionCatalog.distribution(fromStanName: distName, args: args) else {
      return nil
    }
    return (name, dist)
  }

  private static func lastIdentifier(in s: String) -> String? {
    let chars = Array(s.trimmingCharacters(in: .whitespaces))
    guard !chars.isEmpty else { return nil }
    var end = chars.count
    while end > 0, !isIdentChar(chars[end - 1]) { end -= 1 }
    var start = end
    while start > 0, isIdentChar(chars[start - 1]) { start -= 1 }
    guard start < end else { return nil }
    return String(chars[start..<end])
  }

  private static func isIdentChar(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == "_"
  }

  private static func splitTopLevelCommas(_ s: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for c in s {
      switch c {
      case "(", "[": depth += 1; current.append(c)
      case ")", "]": depth -= 1; current.append(c)
      case "," where depth == 0:
        parts.append(current)
        current = ""
      default:
        current.append(c)
      }
    }
    if !current.trimmingCharacters(in: .whitespaces).isEmpty || !parts.isEmpty {
      parts.append(current)
    }
    return parts
  }

  // MARK: - Helpers

  /// `lhs = inv_logit(rhs)` → `.link(.logit, …)`, `exp` → `.log`,
  /// `logit` → `.invLogit`; anything else is a plain deterministic
  /// assignment. The case names follow ulam (the link), the Stan
  /// emission is the inverse — see `LinkFunction`.
  private static func reconstructAssignment(lhs: String, rhs: String) -> Statement {
    if let inner = singleCall(rhs, "inv_logit") {
      return .link(function: .logit, lhs: lhs, rhs: Expression(inner))
    }
    if let inner = singleCall(rhs, "exp") {
      return .link(function: .log, lhs: lhs, rhs: Expression(inner))
    }
    if let inner = singleCall(rhs, "logit") {
      return .link(function: .invLogit, lhs: lhs, rhs: Expression(inner))
    }
    return .deterministic(lhs: lhs, rhs: Expression(rhs))
  }

  /// If `rhs` is exactly `fn(<balanced>)` — the call wraps the whole
  /// expression — return its inner source; otherwise nil. Guards against
  /// `exp(x) + exp(y)`, where the trailing `)` doesn't match the first `(`.
  private static func singleCall(_ rhs: String, _ fn: String) -> String? {
    let prefix = fn + "("
    guard rhs.hasPrefix(prefix), rhs.hasSuffix(")") else { return nil }
    let chars = Array(rhs)
    let openIdx = fn.count   // index of the '(' right after the name
    var depth = 0
    for i in openIdx..<chars.count {
      if chars[i] == "(" { depth += 1 }
      else if chars[i] == ")" {
        depth -= 1
        if depth == 0 {
          return i == chars.count - 1 ? String(chars[(openIdx + 1)..<i]) : nil
        }
      }
    }
    return nil
  }

  private static func toTruncation(_ t: StanTruncation?) -> Truncation {
    guard let t else { return .none }
    return Truncation(lower: t.lower.map { DistributionCatalog.distributionArg(from: $0) },
                      upper: t.upper.map { DistributionCatalog.distributionArg(from: $0) })
  }

  /// Identifier-like and not a numeric literal.
  private static func isSymbol(_ s: String) -> Bool {
    if Double(s) != nil { return false }
    guard let first = s.first, first == "_" || first.isLetter else { return false }
    return s.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  private static func likelihoodName(_ s: Statement) -> String {
    if case let .likelihood(lhs, _, _, _) = s { return lhs }
    return ""
  }
}
