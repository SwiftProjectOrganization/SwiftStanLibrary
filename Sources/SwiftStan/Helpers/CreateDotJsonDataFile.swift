//
//  InstallJsonDataFile.swift
//  Stan
//
//  Created by Robert Goedman on 11/22/25.
//

import Foundation

struct StanData: Codable {
  let N: Int
  let y: [Int]
  
  init(y: [Int] = [0, 1, 0, 1, 1, 0, 1, 1, 1, 0]) {
    self.y = y
    self.N = y.count
  }
}

func createDotJsonDataFile<T: Encodable>(data: T = StanData(),
                                         model: String) -> (String, String) {

  return createDotJsonFile(data, model: model)
}
