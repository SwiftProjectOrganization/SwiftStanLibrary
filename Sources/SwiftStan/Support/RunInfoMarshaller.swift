//
//  RunInfoMarshaller.swift
//  SwiftStan
//
//  Hand-rolled JSON writer for the cleaned `<name>.config.json`,
//  mirroring `Ulam/Data/DataMarshaller.swift`. The motivation is the
//  same: Swift's `String(_:)` on a `Double` emits the shortest
//  round-trippable form (e.g. `"0.05"`), whereas
//  `JSONSerialization.data(... .prettyPrinted)` re-renders that same
//  value as `"0.050000000000000003"`. The output matches what cmdstan
//  itself wrote, byte-for-byte for the numeric literals it emitted.
//
//  Walks an `Any` tree produced by `JSONSerialization.jsonObject` —
//  i.e. NSDictionary / NSArray / NSNumber / NSString / NSNull — and
//  writes a sorted-key, 2-space-indented JSON document.
//

import Foundation

enum RunInfoMarshaller {
  /// Encode a JSON value tree (as returned by `JSONSerialization.jsonObject`)
  /// into UTF-8 JSON text. Object keys are sorted; arrays preserve order.
  static func encodeJSON(_ value: Any) -> Data {
    var out = ""
    write(value, into: &out, indent: 0)
    out.append("\n")
    return Data(out.utf8)
  }

  private static func write(_ value: Any, into out: inout String, indent: Int) {
    if value is NSNull {
      out.append("null")
      return
    }
    if let n = value as? NSNumber {
      writeNumber(n, into: &out)
      return
    }
    if let s = value as? String {
      out.append("\"")
      out.append(escape(s))
      out.append("\"")
      return
    }
    if let dict = value as? [String: Any] {
      writeObject(dict, into: &out, indent: indent)
      return
    }
    if let array = value as? [Any] {
      writeArray(array, into: &out, indent: indent)
      return
    }
    out.append("null")
  }

  private static func writeObject(_ dict: [String: Any],
                                  into out: inout String,
                                  indent: Int) {
    if dict.isEmpty {
      out.append("{}")
      return
    }
    let pad = String(repeating: "  ", count: indent)
    let innerPad = String(repeating: "  ", count: indent + 1)
    out.append("{\n")
    let keys = dict.keys.sorted()
    for (i, key) in keys.enumerated() {
      out.append(innerPad)
      out.append("\"")
      out.append(escape(key))
      out.append("\" : ")
      write(dict[key]!, into: &out, indent: indent + 1)
      if i < keys.count - 1 { out.append(",") }
      out.append("\n")
    }
    out.append(pad)
    out.append("}")
  }

  private static func writeArray(_ array: [Any],
                                 into out: inout String,
                                 indent: Int) {
    if array.isEmpty {
      out.append("[]")
      return
    }
    let pad = String(repeating: "  ", count: indent)
    let innerPad = String(repeating: "  ", count: indent + 1)
    out.append("[\n")
    for (i, element) in array.enumerated() {
      out.append(innerPad)
      write(element, into: &out, indent: indent + 1)
      if i < array.count - 1 { out.append(",") }
      out.append("\n")
    }
    out.append(pad)
    out.append("]")
  }

  /// `JSONSerialization` parses every JSON number into NSNumber. The
  /// underlying Objective-C type tag distinguishes booleans (`c`),
  /// integer widths (`i`/`s`/`l`/`q` and unsigned variants), and
  /// floating-point (`f`/`d`). We can't use a Swift `as? Bool` cast
  /// because NSNumber(1) bridges to `true` too.
  private static func writeNumber(_ n: NSNumber, into out: inout String) {
    let type = String(cString: n.objCType)
    let tag = type.first ?? " "
    if tag == "c" || tag == "B" {
      out.append(n.boolValue ? "true" : "false")
    } else if "iIsSlLqQ".contains(tag) {
      out.append(n.stringValue)
    } else {
      out.append(String(n.doubleValue))
    }
  }

  private static func escape(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count)
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"":     result.append("\\\"")
      case "\\":     result.append("\\\\")
      case "\n":     result.append("\\n")
      case "\r":     result.append("\\r")
      case "\t":     result.append("\\t")
      case "\u{08}": result.append("\\b")
      case "\u{0C}": result.append("\\f")
      default:
        if scalar.value < 0x20 {
          result.append(String(format: "\\u%04x", scalar.value))
        } else {
          result.append(Character(scalar))
        }
      }
    }
    return result
  }
}
