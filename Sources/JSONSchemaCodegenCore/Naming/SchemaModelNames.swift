/// Pure, order-independent allocation of unescaped ASCII model and case names.
///
/// Type names retain an existing uppercase-leading ASCII alphanumeric spelling.
/// Otherwise, ASCII words split at separators and mechanical camel-case boundaries,
/// then use PascalCase (types) or lowerCamelCase (cases), without acronym dictionaries.
/// Empty evidence becomes `Model`/`alternative`; these also prefix leading digits.
///
/// All preferred names are protected before context is considered. Competing names
/// consume nearest-first context cumulatively, then append an underscore and the
/// first eight lowercase hex digits of FNV-1a64 over the semantic ID's UTF-8 bytes.
/// Colliding suffixes extend one digit at a time, never using traversal counters.
/// Locations are diagnostic-only and never contribute to source names.
/// Callers escape keywords at emission, and reserve their root and enclosing symbols.
enum SchemaModelNames {
  /// The named emitter must use this prefix for private adapters and factories.
  /// Explicit public names with this prefix are rejected in both namespaces.
  static let helperPrefix = "_JSONSchemaCodegen"

  static func typeNames(
    for requests: [SchemaModelNameRequest],
    reserved: Set<String> = []
  ) throws -> [String: String] {
    try allocate(requests, kind: .type, reserved: reserved.union(runtimeTypeNames))
  }

  static func caseNames(
    for requests: [SchemaModelNameRequest],
    reserved: Set<String> = []
  ) throws -> [String: String] {
    try allocate(requests, kind: .enumCase, reserved: reserved)
  }

  private enum Kind {
    case type
    case enumCase

    var fallback: String { self == .type ? "Model" : "alternative" }
    var description: String { self == .type ? "type" : "case" }
  }

  private struct Candidate {
    let request: SchemaModelNameRequest
    let base: String
    let contexts: [String]
    var contextIndex = 0
    var suffixLength = 8

    var suffixStem: String { contexts.last ?? base }
  }

  private static func allocate(
    _ requests: [SchemaModelNameRequest],
    kind: Kind,
    reserved: Set<String>
  ) throws -> [String: String] {
    var unique: [String: SchemaModelNameRequest] = [:]
    for request in requests.sorted(by: {
      orderingKey($0).lexicographicallyPrecedes(orderingKey($1))
    }) {
      if let previous = unique[request.id], previous != request {
        throw error(
          request,
          "Conflicting naming metadata for ID \(String(reflecting: request.id)): "
            + "\(evidence(previous)) at \(location(previous)) and "
            + "\(evidence(request)) at \(location(request))."
        )
      }
      unique[request.id] = request
    }

    let ordered = unique.values.sorted { $0.id < $1.id }
    var result: [String: String] = [:]
    var owners: [String: [SchemaModelNameRequest]] = [:]
    var protected = reserved
    for request in ordered {
      guard let name = request.explicitName else { continue }
      guard isIdentifier(name), name != "Self" else {
        throw error(
          request,
          "Invalid explicit \(kind.description) name \(String(reflecting: name)) at "
            + "\(location(request)); use an ASCII Swift identifier other than '_' or 'Self'."
        )
      }
      guard !isReserved(name, in: reserved) else {
        throw error(
          request,
          "Explicit \(kind.description) name \(String(reflecting: name)) at "
            + "\(location(request)) conflicts with a reserved name or helper prefix "
            + "\(String(reflecting: helperPrefix))."
        )
      }
      if let previous = owners[name]?.first {
        throw error(
          request,
          "Duplicate explicit \(kind.description) name \(String(reflecting: name)) at "
            + "\(location(previous)) and \(location(request))."
        )
      }
      result[request.id] = name
      owners[name] = [request]
      protected.insert(name)
    }

    var candidates = ordered.filter { $0.explicitName == nil }.map { request in
      let base = normalized(request.preferredName, kind: kind)
      var prefix = ""
      var contexts: [String] = []
      for context in request.context where !words(context).isEmpty {
        prefix = normalized(context, kind: .type) + prefix
        let name =
          kind == .type ? prefix + base : normalized(prefix + uppercasingFirst(base), kind: kind)
        if contexts.last != name { contexts.append(name) }
      }
      return Candidate(request: request, base: base, contexts: contexts)
    }
    let baseGroups = Dictionary(grouping: candidates.indices, by: { candidates[$0].base })
    for base in baseGroups.keys.sorted() {
      let indices = baseGroups[base]!
      if indices.count == 1, !isReserved(base, in: protected) {
        let request = candidates[indices[0]].request
        result[request.id] = base
      }
      owners[base, default: []].append(contentsOf: indices.map { candidates[$0].request })
      protected.insert(base)
    }

    // Allocate simultaneous proposals, so neither input order nor another group's
    // number of attempts decides who gets a contextual spelling.
    while true {
      var proposals: [String: [Int]] = [:]
      for index in candidates.indices where result[candidates[index].request.id] == nil {
        while candidates[index].contextIndex < candidates[index].contexts.count {
          let name = candidates[index].contexts[candidates[index].contextIndex]
          if !isReserved(name, in: protected) {
            proposals[name, default: []].append(index)
            break
          }
          candidates[index].contextIndex += 1
        }
      }
      if proposals.isEmpty { break }
      for name in proposals.keys.sorted() {
        let indices = proposals[name]!
        if indices.count == 1 {
          let request = candidates[indices[0]].request
          result[request.id] = name
          owners[name] = [request]
          protected.insert(name)
        } else {
          for index in indices { candidates[index].contextIndex += 1 }
        }
      }
    }

    let digests = candidates.map { digest($0.request.id) }
    while result.count < ordered.count {
      var proposals: [String: [Int]] = [:]
      for index in candidates.indices where result[candidates[index].request.id] == nil {
        let candidate = candidates[index]
        let name = candidate.suffixStem + "_" + digests[index].prefix(candidate.suffixLength)
        proposals[name, default: []].append(index)
      }
      for name in proposals.keys.sorted() {
        let indices = proposals[name]!
        if indices.count == 1, !isReserved(name, in: protected) {
          let request = candidates[indices[0]].request
          result[request.id] = name
          owners[name] = [request]
          protected.insert(name)
        } else {
          for index in indices {
            guard candidates[index].suffixLength < 16 else {
              let request = candidates[index].request
              let collisions = (owners[name] ?? []) + indices.map { candidates[$0].request }
              let locations = Set(collisions.map(location)).sorted().joined(separator: ", ")
              throw error(
                request,
                "Cannot allocate a unique \(kind.description) name: FNV-1a64 suffix exhausted "
                  + "for \(String(reflecting: name)) at \(locations)"
                  + (reserved.contains(name) ? "; the name is reserved." : ".")
              )
            }
            candidates[index].suffixLength += 1
          }
        }
      }
    }
    return result
  }

  private static func normalized(_ name: String, kind: Kind) -> String {
    if kind == .type, let first = name.utf8.first, isUppercase(first),
      name.utf8.allSatisfy(isAlphanumeric)
    {
      return name
    }
    let tokens = words(name)
    var result = tokens.enumerated().map { index, token in
      let lowercase = token.lowercased()
      return kind == .enumCase && index == 0 ? lowercase : uppercasingFirst(lowercase)
    }.joined()
    if result.isEmpty { return kind.fallback }
    if let first = result.utf8.first, isDigit(first) {
      result = kind.fallback + result
    }
    return result
  }

  private static func words(_ name: String) -> [String] {
    let bytes = Array(name.utf8)
    var words: [String] = []
    var word: [UInt8] = []
    for index in bytes.indices {
      let byte = bytes[index]
      guard isAlphanumeric(byte) else {
        if !word.isEmpty {
          words.append(String(decoding: word, as: UTF8.self))
          word.removeAll(keepingCapacity: true)
        }
        continue
      }
      if let previous = word.last, isUppercase(byte),
        isLowercase(previous) || isDigit(previous)
          || (isUppercase(previous) && index + 1 < bytes.count && isLowercase(bytes[index + 1]))
      {
        words.append(String(decoding: word, as: UTF8.self))
        word.removeAll(keepingCapacity: true)
      }
      word.append(byte)
    }
    if !word.isEmpty { words.append(String(decoding: word, as: UTF8.self)) }
    return words
  }

  private static func uppercasingFirst(_ name: String) -> String {
    guard let first = name.first else { return name }
    return first.uppercased() + name.dropFirst()
  }

  private static func isIdentifier(_ name: String) -> Bool {
    guard name != "_", let first = name.utf8.first,
      isUppercase(first) || isLowercase(first) || first == 95
    else { return false }
    return name.utf8.allSatisfy { isAlphanumeric($0) || $0 == 95 }
  }

  private static func isReserved(_ name: String, in reserved: Set<String>) -> Bool {
    name == "Self" || name.hasPrefix(helperPrefix) || reserved.contains(name)
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    isUppercase(byte) || isLowercase(byte) || isDigit(byte)
  }

  private static func isUppercase(_ byte: UInt8) -> Bool { (65...90).contains(byte) }
  private static func isLowercase(_ byte: UInt8) -> Bool { (97...122).contains(byte) }
  private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

  private static func digest(_ id: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    let hexadecimal = String(hash, radix: 16)
    return String(repeating: "0", count: 16 - hexadecimal.count) + hexadecimal
  }

  private static func orderingKey(_ request: SchemaModelNameRequest) -> [String] {
    [
      request.id, request.documentURI?.absoluteString ?? "", request.pointer,
      request.preferredName, request.explicitName == nil ? "0" : "1", request.explicitName ?? "",
    ] + request.context
  }

  private static func evidence(_ request: SchemaModelNameRequest) -> String {
    "preferred \(String(reflecting: request.preferredName)), "
      + "explicit \(String(reflecting: request.explicitName)), context \(String(reflecting: request.context))"
  }

  private static func location(_ request: SchemaModelNameRequest) -> String {
    (request.documentURI?.absoluteString ?? "") + "#" + request.pointer
  }

  private static func error(
    _ request: SchemaModelNameRequest, _ message: String
  ) -> SchemaGenerationError {
    SchemaGenerationError(
      pointer: request.pointer, message: message, documentURI: request.documentURI)
  }

  private static let runtimeTypeNames: Set<String> = [
    "Any", "AnyObject", "Array", "Bool", "Double", "Float", "Int", "Int8", "Int16",
    "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "String",
    "Substring", "Dictionary", "Set", "Optional", "Never", "Void", "Sendable",
    "Equatable", "Hashable", "Codable", "Decodable", "Encodable", "CodingKey",
    "Decoder", "Encoder", "Error", "Result", "URL", "UUID", "Date", "Data",
    "Swift", "Foundation", "OrderedJSON", "JSONSchemaBuilder", "Schemable",
    "JSONValue", "JSONSchemaComponent", "JSONComponents", "JSONComposition",
    "JSONReference", "JSONBooleanSchema", "JSONAnyValue", "JSONString",
    "JSONInteger", "JSONNumber", "JSONBoolean", "JSONNull", "JSONArray",
    "JSONObject", "JSONProperty",
  ]
}
