//
//  RunInfoIO.swift
//  SwiftStan
//
//  Reads `<Results>/<name>.config.json` — cmdstan emits
//  `<name>_output_config.json` when `save_cmdstan_config=true`, and
//  `StanSample.swift` renames it to `<name>.config.json` right after
//  the run. A second entry point cleans that same file in place
//  (paths stripped to basenames, sorted keys, pretty-printed) so the
//  file is portable across machines.
//
//  Filename note: this file is `RunInfoIO.swift` (not `RunInfo.swift`)
//  to avoid an APFS case-insensitive `.o` collision with
//  `Commands/Runinfo.swift` — same pattern as `Methods/RunStanSummary.swift`
//  vs `Commands/Stansummary.swift`. The Swift type stays `RunInfo`.
//

import Foundation

// MARK: - Top-level

public struct RunInfo: Decodable {
  public let stanMajorVersion: String
  public let stanMinorVersion: String
  public let stanPatchVersion: String
  public let modelName: String
  public let startDatetime: String
  public let method: MethodConfig
  public let id: Int
  public let data: DataConfig
  public let initSpec: String
  public let random: RandomConfig
  public let output: OutputConfig
  public let numThreads: Int
  public let mpiEnabled: Bool
  public let stancVersion: String
  public let stancflags: String

  enum CodingKeys: String, CodingKey {
    case stanMajorVersion = "stan_major_version"
    case stanMinorVersion = "stan_minor_version"
    case stanPatchVersion = "stan_patch_version"
    case modelName = "model_name"
    case startDatetime = "start_datetime"
    case method
    case id
    case data
    case initSpec = "init"
    case random
    case output
    case numThreads = "num_threads"
    case mpiEnabled = "mpi_enabled"
    case stancVersion = "stanc_version"
    case stancflags
  }
}

// MARK: - Method (tagged union)

public enum MethodConfig: Decodable {
  case sample(SampleConfig)
  case optimize(OptimizeConfig)
  case laplace(LaplaceConfig)
  case pathfinder(PathfinderConfig)

  private enum CodingKeys: String, CodingKey {
    case value, sample, optimize, laplace, pathfinder
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value = try container.decode(String.self, forKey: .value)
    switch value {
    case "sample":
      self = .sample(try container.decode(SampleConfig.self, forKey: .sample))
    case "optimize":
      self = .optimize(try container.decode(OptimizeConfig.self, forKey: .optimize))
    case "laplace":
      self = .laplace(try container.decode(LaplaceConfig.self, forKey: .laplace))
    case "pathfinder":
      self = .pathfinder(try container.decode(PathfinderConfig.self, forKey: .pathfinder))
    default:
      throw RunInfoError.unsupportedMethod(value)
    }
  }
}

// MARK: - Sample (fully typed against a real cmdstan emission)

public struct SampleConfig: Decodable {
  public let numSamples: Int
  public let numWarmup: Int
  public let saveWarmup: Bool
  public let thin: Int
  public let adapt: AdaptConfig
  public let algorithm: AlgorithmConfig
  public let numChains: Int

  enum CodingKeys: String, CodingKey {
    case numSamples = "num_samples"
    case numWarmup = "num_warmup"
    case saveWarmup = "save_warmup"
    case thin, adapt, algorithm
    case numChains = "num_chains"
  }
}

public struct AdaptConfig: Decodable {
  public let engaged: Bool
  public let gamma: Double
  public let delta: Double
  public let kappa: Double
  public let t0: Double
  public let initBuffer: Int
  public let termBuffer: Int
  public let window: Int
  public let saveMetric: Bool

  enum CodingKeys: String, CodingKey {
    case engaged, gamma, delta, kappa, t0
    case initBuffer = "init_buffer"
    case termBuffer = "term_buffer"
    case window
    case saveMetric = "save_metric"
  }
}

public struct AlgorithmConfig: Decodable {
  public let value: String
  public let hmc: HmcConfig?
}

public struct HmcConfig: Decodable {
  public let engine: EngineConfig
  public let metric: MetricConfig
  public let metricFile: String
  public let stepsize: Double
  public let stepsizeJitter: Double

  enum CodingKeys: String, CodingKey {
    case engine, metric
    case metricFile = "metric_file"
    case stepsize
    case stepsizeJitter = "stepsize_jitter"
  }
}

public struct EngineConfig: Decodable {
  public let value: String
  public let nuts: NutsConfig?
}

public struct NutsConfig: Decodable {
  public let maxDepth: Int
  enum CodingKeys: String, CodingKey { case maxDepth = "max_depth" }
}

public struct MetricConfig: Decodable {
  public let value: String
}

// MARK: - Shared top-level sub-records

public struct DataConfig: Decodable {
  public let file: String
}

public struct RandomConfig: Decodable {
  public let seed: Int
}

public struct OutputConfig: Decodable {
  public let file: String
  public let diagnosticFile: String
  public let refresh: Int
  public let sigFigs: Int
  public let profileFile: String
  public let saveCmdstanConfig: Bool

  enum CodingKeys: String, CodingKey {
    case file
    case diagnosticFile = "diagnostic_file"
    case refresh
    case sigFigs = "sig_figs"
    case profileFile = "profile_file"
    case saveCmdstanConfig = "save_cmdstan_config"
  }
}

// MARK: - Placeholder configs (non-sample methods)
//
// None of optimize / laplace / pathfinder currently sets
// `save_cmdstan_config=true`, so no real-world JSON has been observed
// for them yet. Each placeholder decodes the whole nested object into
// a `[String: JSONValue]` dict so the file still parses; flesh into
// typed fields when those wrappers start emitting config JSON.

public struct OptimizeConfig: Decodable {
  public let raw: [String: JSONValue]
  public init(from decoder: Decoder) throws {
    self.raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
  }
}

public struct LaplaceConfig: Decodable {
  public let raw: [String: JSONValue]
  public init(from decoder: Decoder) throws {
    self.raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
  }
}

public struct PathfinderConfig: Decodable {
  public let raw: [String: JSONValue]
  public init(from decoder: Decoder) throws {
    self.raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
  }
}

// MARK: - JSONValue helper for the placeholder configs

public enum JSONValue: Decodable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
    if let v = try? c.decode(Int.self)    { self = .int(v);    return }
    if let v = try? c.decode(Double.self) { self = .double(v); return }
    if let v = try? c.decode(String.self) { self = .string(v); return }
    if let v = try? c.decode([JSONValue].self)        { self = .array(v);  return }
    if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
    throw DecodingError.dataCorruptedError(in: c,
      debugDescription: "Unrecognised JSON value")
  }
}

// MARK: - Errors

public enum RunInfoError: Error, CustomStringConvertible {
  case fileNotFound(String)
  case decodeFailed(underlying: Error)
  case unsupportedMethod(String)
  case writeFailed(URL, underlying: Error)
  case malformedJSON(String)

  public var description: String {
    switch self {
    case .fileNotFound(let p):
      return "runinfo: \(p) not found (run `sample` first — it writes `<name>.config.json`)"
    case .decodeFailed(let e):
      return "runinfo: could not decode JSON: \(e)"
    case .unsupportedMethod(let m):
      return "runinfo: unsupported method `\(m)` (sample, optimize, laplace, pathfinder)"
    case .writeFailed(let u, let e):
      return "runinfo: could not write \(u.path): \(e)"
    case .malformedJSON(let m):
      return "runinfo: malformed JSON — \(m)"
    }
  }
}

// MARK: - Entry points

/// Read `<dir>/<modelName>.config.json` into a typed `RunInfo`.
public func readRunInfo(dirUrl: URL, modelName: String) throws -> RunInfo {
  let url = dirUrl.appendingPathComponent("\(modelName).config.json")
  guard FileManager.default.fileExists(atPath: url.path) else {
    throw RunInfoError.fileNotFound(url.path)
  }
  let data: Data
  do { data = try Data(contentsOf: url) }
  catch { throw RunInfoError.decodeFailed(underlying: error) }
  do { return try JSONDecoder().decode(RunInfo.self, from: data) }
  catch { throw RunInfoError.decodeFailed(underlying: error) }
}

/// Strip absolute-path prefixes from `data.file` and `output.file` down
/// to their basenames and rewrite `<dir>/<modelName>.config.json` in
/// place with sorted keys + pretty-printing via the hand-rolled
/// `RunInfoMarshaller` (so e.g. `0.05` stays `0.05`, not
/// `0.050000000000000003`).
@discardableResult
public func writeCleanRunInfo(dirUrl: URL, modelName: String) throws -> URL {
  let configURL = dirUrl.appendingPathComponent("\(modelName).config.json")
  guard FileManager.default.fileExists(atPath: configURL.path) else {
    throw RunInfoError.fileNotFound(configURL.path)
  }
  let raw = try Data(contentsOf: configURL)
  guard var dict = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
    throw RunInfoError.malformedJSON("top-level value is not an object")
  }
  if var d = dict["data"] as? [String: Any], let f = d["file"] as? String {
    d["file"] = (f as NSString).lastPathComponent
    dict["data"] = d
  }
  if var o = dict["output"] as? [String: Any], let f = o["file"] as? String {
    o["file"] = (f as NSString).lastPathComponent
    dict["output"] = o
  }
  let cleaned = RunInfoMarshaller.encodeJSON(dict)
  do { try cleaned.write(to: configURL, options: .atomic) }
  catch { throw RunInfoError.writeFailed(configURL, underlying: error) }
  return configURL
}
