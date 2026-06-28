//
//  AlistParserTests.swift
//  StanTests
//
//  Slice A coverage for the alist parser: lexer + statement-level
//  parser shape against the chimpanzees m12.5 reference alist.
//

import Foundation
import Testing
@testable import SwiftStan

@Suite("Alist parser Slice A tests")
struct AlistParserTests {
  init() { _ = TestCaseRootBootstrap.install }


  static let chimpanzeesAlist = """
    m12.5 <- map2stan(
        alist(
            pulled_left ~ dbinom( 1 , p ),
            logit(p) <- a + a_actor[actor] + a_block[block_id] +
                        (bp + bpc*condition)*prosoc_left,
            a_actor[actor] ~ dnorm( 0 , sigma_actor ),
            a_block[block_id] ~ dnorm( 0 , sigma_block ),
            c(a,bp,bpc) ~ dnorm(0,10),
            sigma_actor ~ dcauchy(0,1),
            sigma_block ~ dcauchy(0,1)
        ) ,
        data=d, warmup=1000 , iter=6000 , chains=4 , cores=3 )
    """

  @Test func chimpanzeesParsesIntoSevenStatements() throws {
    let stmts = try AlistParser.parse(Self.chimpanzeesAlist)
    #expect(stmts.count == 7)
  }

  @Test func firstStatementIsBernoulliLikelihood() throws {
    let stmts = try AlistParser.parse(Self.chimpanzeesAlist)
    guard case let .sample(lhs, dist, _) = stmts[0] else {
      Issue.record("first statement is not a sample")
      return
    }
    #expect(lhs == .scalar("pulled_left"))
    #expect(dist.name == "dbinom")
    #expect(dist.args.count == 2)
    #expect(dist.args[0] == .literal(.integer(1)))
    #expect(dist.args[1] == .identifier("p"))
  }

  @Test func secondStatementIsLogitLink() throws {
    let stmts = try AlistParser.parse(Self.chimpanzeesAlist)
    guard case let .link(fn, target, _) = stmts[1] else {
      Issue.record("second statement is not a link")
      return
    }
    #expect(fn == .logit)
    #expect(target == "p")
  }

  @Test func varyingPriorsParseWithIndexedLhs() throws {
    let stmts = try AlistParser.parse(Self.chimpanzeesAlist)
    guard case let .sample(lhs1, dist1, _) = stmts[2] else {
      Issue.record("3rd statement should be a sample"); return
    }
    #expect(lhs1 == .indexed(name: "a_actor", indexColumn: "actor"))
    #expect(dist1.name == "dnorm")

    guard case let .sample(lhs2, _, _) = stmts[3] else {
      Issue.record("4th statement should be a sample"); return
    }
    #expect(lhs2 == .indexed(name: "a_block", indexColumn: "block_id"))
  }

  @Test func groupPriorCollectsAllNames() throws {
    let stmts = try AlistParser.parse(Self.chimpanzeesAlist)
    guard case let .sample(lhs, _, _) = stmts[4] else {
      Issue.record("5th statement should be a sample"); return
    }
    #expect(lhs == .group(["a", "bp", "bpc"]))
  }

  @Test func cauchyPriorsTrailing() throws {
    let stmts = try AlistParser.parse(Self.chimpanzeesAlist)
    guard case let .sample(lhs5, dist5, _) = stmts[5] else {
      Issue.record("6th statement"); return
    }
    #expect(lhs5 == .scalar("sigma_actor"))
    #expect(dist5.name == "dcauchy")
    #expect(dist5.args.count == 2)

    guard case let .sample(lhs6, _, _) = stmts[6] else {
      Issue.record("7th statement"); return
    }
    #expect(lhs6 == .scalar("sigma_block"))
  }

  @Test func missingAlistKeywordThrows() throws {
    #expect(throws: AlistParserError.self) {
      _ = try AlistParser.parse("x <- 42")
    }
  }

  // MARK: - dmvnormchol (correlated varying effects) shape

  @Test func cafeGroupIndexedLhsParses() throws {
    let src = """
      alist(
        c(a, b)[cafe] ~ dmvnormchol(c(a_bar, b_bar), L_Omega, sigma_ab)
      )
      """
    let stmts = try AlistParser.parse(src)
    #expect(stmts.count == 1)
    guard case let .sample(lhs, dist, _) = stmts[0] else {
      Issue.record("statement should be a sample"); return
    }
    #expect(lhs == .groupIndexed(names: ["a", "b"], indexColumn: "cafe"))
    #expect(dist.name == "dmvnormchol")
    #expect(dist.args.count == 3)
    // The `c(a_bar, b_bar)` arg is synthesised to the Stan row-vector
    // literal so it flows through DistributionArg.symbol downstream.
    #expect(dist.args[0] == .identifier("[a_bar, b_bar]'"))
    #expect(dist.args[1] == .identifier("L_Omega"))
    #expect(dist.args[2] == .identifier("sigma_ab"))
  }

  @Test func dlkjcorrPriorParses() throws {
    let src = "alist(L_Omega ~ dlkjcorr(2))"
    let stmts = try AlistParser.parse(src)
    #expect(stmts.count == 1)
    guard case let .sample(lhs, dist, _) = stmts[0] else {
      Issue.record("statement should be a sample"); return
    }
    #expect(lhs == .scalar("L_Omega"))
    #expect(dist.name == "dlkjcorr")
    #expect(dist.args == [.literal(.integer(2))])
  }

  // MARK: - Bare-identifier (identity-link / deterministic) parsing

  /// McElreath's bare `<target> <- <expr>` form should parse as an
  /// identity-link AST node; the lowering pass turns it into a
  /// `Statement.deterministic(...)` downstream.
  @Test func bareIdentifierLhsParsesAsIdentityLink() throws {
    let src = "alist(mu <- a + bA*A + bR*R)"
    let stmts = try AlistParser.parse(src)
    #expect(stmts.count == 1)
    guard case let .link(fn, target, _) = stmts[0] else {
      Issue.record("statement should be a link"); return
    }
    #expect(fn == .identity)
    #expect(target == "mu")
  }

  /// Bare deterministic alongside a likelihood — verify both
  /// statements parse and order is preserved.
  @Test func bareIdentifierLhsAndLikelihoodCoexist() throws {
    let src = """
    alist(
      div_obs ~ dnorm(div_est, div_sd),
      mu <- a + bA*A + bR*R
    )
    """
    let stmts = try AlistParser.parse(src)
    #expect(stmts.count == 2)
    if case .sample = stmts[0] {} else {
      Issue.record("statement 0 should be a sample")
    }
    if case let .link(fn, target, _) = stmts[1] {
      #expect(fn == .identity)
      #expect(target == "mu")
    } else {
      Issue.record("statement 1 should be a link")
    }
  }
}
