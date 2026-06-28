//
//  createDotStanFile.swift
//  Stan
//
//  Created by Robert Goedman on 11/22/25.
//
// I typically copy the 4 files in the "Helpers" folder to work project, e.g. like SwiftStats.
//

import Foundation

let bernouli_stan =
"""
data {
  int<lower=0> N;
  array[N] int<lower=0, upper=1> y;
}
parameters {
  real<lower=0, upper=1> theta;
}
model {
  theta ~ beta(1, 1); // uniform prior on interval 0,1
  y ~ bernoulli(theta);
}
"""

func createDotStanModelFile(stan: String = bernouli_stan,
                                   model: String = "bernoulli") -> (String, String) {

  return createDotStanFile(stan, model: model)
}
