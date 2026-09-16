/// The Swift representation generated for a schema's parsed output.
public enum SchemaOutputStyle: String, Codable, Equatable, Sendable {
  /// Preserve the legacy tuple, singleton, and numbered-union output.
  case tuples
  /// Emit named models inside the generated namespace.
  case models
}

/// How named models handle object cycles that require storage indirection.
public enum RecursiveObjectStrategy: String, Codable, Equatable, Sendable {
  /// Diagnose object-layout cycles that cannot be represented by value types.
  case valueTypes
  /// Permit final immutable classes for objects in inline-layout cycles.
  case immutableClasses
}

/// Storage for object keys not represented by modeled properties or typed extras.
public enum UnknownPropertyStrategy: String, Codable, Equatable, Sendable {
  /// Keep the existing schema-directed projection.
  case discard
  /// Preserve unmodeled keys as JSONValue without changing schema validation.
  case preserve
}

/// Exact Swift names keyed by schema-location selectors.
public struct SchemaNameOverrides: Codable, Equatable, Sendable {
  /// Type-bearing schema locations; the complete root retains the name `Value`.
  public var typeNames: [String: String]
  /// Union-branch locations or original string-enum entry locations (`/enum/0`).
  public var caseNames: [String: String]

  public init(typeNames: [String: String] = [:], caseNames: [String: String] = [:]) {
    self.typeNames = typeNames
    self.caseNames = caseNames
  }
}

/// Shared generation options for the core, macro, command line, and plugin.
public struct SchemaGenerationOptions: Codable, Equatable, Sendable {
  public var output: SchemaOutputStyle
  public var recursiveObjects: RecursiveObjectStrategy
  public var names: SchemaNameOverrides
  public var unknownProperties: UnknownPropertyStrategy

  public init(
    output: SchemaOutputStyle = .tuples,
    recursiveObjects: RecursiveObjectStrategy = .valueTypes,
    names: SchemaNameOverrides = .init(),
    unknownProperties: UnknownPropertyStrategy = .discard
  ) {
    self.output = output
    self.recursiveObjects = recursiveObjects
    self.names = names
    self.unknownProperties = unknownProperties
  }

  private enum CodingKeys: CodingKey {
    case output, recursiveObjects, names, unknownProperties
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    output = try container.decode(SchemaOutputStyle.self, forKey: .output)
    recursiveObjects = try container.decode(RecursiveObjectStrategy.self, forKey: .recursiveObjects)
    names = try container.decode(SchemaNameOverrides.self, forKey: .names)
    unknownProperties =
      try container.decodeIfPresent(UnknownPropertyStrategy.self, forKey: .unknownProperties)
      ?? .discard
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(output, forKey: .output)
    try container.encode(recursiveObjects, forKey: .recursiveObjects)
    try container.encode(names, forKey: .names)
    if unknownProperties != .discard {
      try container.encode(unknownProperties, forKey: .unknownProperties)
    }
  }
}

/// Checks only identifier spelling; reserved names and collisions need schema context.
package func isSchemaOverrideIdentifier(_ name: String) -> Bool {
  let bytes = Array(name.utf8)
  func isLetter(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || byte == 95
  }
  guard let first = bytes.first, isLetter(first), name != "_" else { return false }
  guard bytes.dropFirst().allSatisfy({ isLetter($0) || (48...57).contains($0) }) else {
    return false
  }
  // These spellings require backticks in a declaration, which exact overrides
  // deliberately do not add. Contextual names and generated reservations belong
  // to the core's symbol allocator.
  let keywords: Set<String> = [
    "Any", "Self", "as", "associatedtype", "break", "case", "catch", "class", "continue",
    "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false",
    "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal",
    "is", "let", "nil", "operator", "precedencegroup", "private", "protocol", "public",
    "repeat", "rethrows", "return", "self", "static", "struct", "subscript", "super", "switch",
    "throw", "throws", "true", "try", "typealias", "var", "where", "while",
  ]
  return !keywords.contains(name)
}
