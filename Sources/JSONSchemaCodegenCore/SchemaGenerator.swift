import Foundation
import OrderedJSON

/// A source expression and the Swift value type it parses.
public struct GeneratedSchema: Equatable, Sendable {
  public let expression: String
  public let outputType: String

  public init(expression: String, outputType: String) {
    self.expression = expression
    self.outputType = outputType
  }
}

/// A generation failure located by a JSON Pointer within the input schema.
public struct SchemaGenerationError: Error, Equatable, Sendable, CustomStringConvertible {
  public let pointer: String
  public let message: String
  public let documentURI: URL?

  public init(pointer: String, message: String, documentURI: URL? = nil) {
    self.pointer = pointer
    self.message = message
    self.documentURI = documentURI
  }

  public var description: String {
    let source = documentURI.map { ($0.isFileURL ? $0.path : $0.absoluteString) + ": " } ?? ""
    return "\(source)#\(pointer): \(message)"
  }
}

/// Lowers a supported JSON Schema 2020-12 document to JSONSchemaBuilder source.
///
/// Generation performs no file or network I/O. References resolve through the
/// explicitly supplied document registry. Unsupported keywords are errors rather
/// than silently weakened schemas.
public struct SchemaGenerator: Sendable {
  public init() {}

  public func generate(_ source: String) throws -> GeneratedSchema {
    let graph = try SchemaReferenceGraph(
      documents: [SchemaDocument(source: source, retrievalURI: URL(fileURLWithPath: "/inline.schema.json"))],
      includeDocumentURI: false
    )
    var emitter = SchemaEmitter()
    return try emitter.plan(graph.root(at: 0))
  }

  /// Generates a batch using a single registry, returning results in input order.
  ///
  /// Every input is registered before any reference is followed. Referenced files
  /// must be included in this array; URLs are identifiers, not fetch instructions.
  public func generate(_ documents: [SchemaDocument]) throws -> [GeneratedSchema] {
    let graph = try SchemaReferenceGraph(documents: documents)
    return try documents.indices.map {
      var emitter = SchemaEmitter()
      return try emitter.plan(graph.root(at: $0))
    }
  }
}

private struct SchemaEmitter {
  private var visitedNodes = 0

  mutating func plan(_ node: ResolvedSchema) throws -> GeneratedSchema {
    do {
      visitedNodes += 1
      guard visitedNodes <= 10_000 else {
        throw failure(node.location.pointer, "Schema expansion exceeds the maximum of 10000 emitted nodes.")
      }
      let generated = try emit(node)
      guard !node.refinements.isEmpty else { return generated }
      let siblings = try node.refinements.map { try plan($0) }
      let constraints = siblings.map {
        "(\n\(indent($0.expression))\n).schemaValue.value"
      }.joined(separator: ",\n")
      return GeneratedSchema(
        expression: """
          {
            var schema = (
          \(indent(indent(generated.expression)))
            ).eraseToAnySchemaComponent()
            schema.schemaValue = .object([
              "allOf": [
                schema.schemaValue.value,
          \(indent(indent(indent(constraints))))
              ]
            ])
            return schema
          }()
          """,
        outputType: generated.outputType
      )
    } catch let error as SchemaGenerationError {
      throw SchemaGenerationError(
        pointer: error.pointer, message: error.message,
        documentURI: error.documentURI ?? node.documentURI
      )
    }
  }

  private mutating func emit(_ node: ResolvedSchema) throws -> GeneratedSchema {
    let value = node.value
    let pointer = node.location.pointer
    if case .boolean(let flag) = value {
      return GeneratedSchema(
        expression: """
          JSONComponents.PassthroughComponent(
            wrapped: JSONBooleanSchema(booleanLiteral: \(flag))
          )
          """,
        outputType: "JSONValue"
      )
    }
    guard let object = value.object else {
      throw failure(pointer, "Expected a schema object or boolean.")
    }
    for key in object.keys where !Self.supportedKeywords.contains(key) {
      throw failure(child(pointer, key), "Unsupported keyword '\(key)'.")
    }

    let (type, nullable) = try schemaType(object["type"], at: child(pointer, "type"))
    var expression: String
    var outputType: String
    switch type {
    case "string":
      expression = "JSONString()"
      outputType = "String"
    case "integer":
      expression = "JSONInteger()"
      outputType = "Int"
    case "number":
      expression = "JSONNumber()"
      outputType = "Double"
    case "boolean":
      expression = "JSONBoolean()"
      outputType = "Bool"
    case "null":
      expression = "JSONNull()"
      outputType = "Void"
    case "object":
      let generated = try objectPlan(node)
      expression = generated.expression
      outputType = generated.outputType
    case "array":
      let itemNode = node.children["items"] ?? ResolvedSchema(
        value: .object([:]), location: node.location.child("items"), documentURI: node.documentURI
      )
      let items = try plan(itemNode)
      expression = "JSONArray {\n\(indent(items.expression))\n}"
      outputType = "[\(items.outputType)]"
      // The upstream array initializer only copies object-shaped item schemas.
      if case .boolean(let flag) = itemNode.value, itemNode.refinements.isEmpty {
        expression = """
          {
            var schema = \(expression)
            schema.schemaValue["items"] = .boolean(\(flag))
            return schema
          }()
          """
      }
    default:
      expression = "JSONAnyValue()"
      outputType = "JSONValue"
    }

    // Type-specific modifiers precede wrappers such as enumValues and orNull.
    for key in object.keys {
      let location = child(pointer, key)
      guard let keyword = object[key] else { continue }
      if let types = Self.keywordTypes[key], !types.contains(type ?? "") {
        throw failure(location, "'\(key)' requires an explicit compatible 'type'.")
      }
      if Self.nonnegativeIntegers.contains(key) {
        let number = try nonnegativeInteger(keyword, at: location)
        expression += "\n.\(key)(\(number))"
      } else if Self.numericKeywords.contains(key) {
        let number = try finiteNumber(keyword, at: location)
        if key == "multipleOf", number <= 0 {
          throw failure(location, "'multipleOf' must be greater than zero.")
        }
        expression += "\n.\(key)(\(number))"
      } else {
        switch key {
        case "pattern", "format":
          let text = try string(keyword, at: location)
          if key == "pattern" {
            do {
              _ = try NSRegularExpression(pattern: text)
            } catch {
              throw failure(location, "Invalid regular expression: \(error.localizedDescription)")
            }
          }
          expression += "\n.\(key)(\(swiftString(text)))"
        case "additionalProperties", "uniqueItems":
          if key == "additionalProperties", keyword.boolean == nil {
            throw failure(location, "Schema-valued additional properties are not yet supported; expected a boolean.")
          }
          expression += "\n.\(key)(\(try boolean(keyword, at: location)))"
        default:
          break
        }
      }
    }

    for key in object.keys {
      let location = child(pointer, key)
      guard let keyword = object[key] else { continue }
      switch key {
      case "title", "description", "$comment", "$id", "$schema", "$anchor":
        let text = try string(keyword, at: location)
        if key == "$schema", text != "https://json-schema.org/draft/2020-12/schema" {
          throw failure(location, "Only the JSON Schema 2020-12 dialect is supported.")
        }
        let method = ["$comment": "comment", "$id": "id", "$schema": "schema", "$anchor": "anchor"][key] ?? key
        expression += "\n.\(method)(\(swiftString(text)))"
      case "readOnly", "writeOnly", "deprecated":
        expression += "\n.\(key)(\(try boolean(keyword, at: location)))"
      case "default", "const":
        let method = key == "const" ? "constant" : "`default`"
        expression += "\n.\(method)(\(try jsonLiteral(keyword, at: location)))"
      case "examples":
        guard keyword.array != nil else {
          throw failure(location, "'examples' must be an array.")
        }
        expression += "\n.examples(\(try jsonLiteral(keyword, at: location)))"
      default:
        break
      }
    }

    if let keyword = object["enum"] {
      let location = child(pointer, "enum")
      guard let values = keyword.array, !values.isEmpty else {
        throw failure(location, "'enum' must be a nonempty array.")
      }
      guard Set(values).count == values.count else {
        throw failure(location, "'enum' values must be unique.")
      }
      expression = """
        JSONComponents.Enum(
          upstream: \(expression),
          cases: [\(try values.map { try jsonLiteral($0, at: location) }.joined(separator: ", "))]
        )
        """
    }
    if nullable {
      expression += "\n.orNull(style: .type)"
      outputType += "?"
    }
    return GeneratedSchema(expression: expression, outputType: outputType)
  }

  private mutating func objectPlan(_ node: ResolvedSchema) throws -> GeneratedSchema {
    let pointer = node.location.pointer
    guard let object = node.value.object else {
      throw failure(pointer, "Expected an object schema.")
    }
    let propertiesValue = object["properties"] ?? .object([:])
    guard let properties = propertiesValue.object else {
      throw failure(child(pointer, "properties"), "'properties' must be an object.")
    }
    var required = Set<String>()
    if let keyword = object["required"] {
      let location = child(pointer, "required")
      guard let values = keyword.array else {
        throw failure(location, "'required' must be an array of unique property names.")
      }
      for (index, value) in values.enumerated() {
        let name = try string(value, at: child(location, String(index)))
        guard required.insert(name).inserted else {
          throw failure(location, "'required' must contain unique property names.")
        }
        guard properties[name] != nil else {
          throw failure(location, "Required property '\(name)' must be declared in 'properties'.")
        }
      }
    }
    var expressions: [String] = []
    var fields: [(name: String, type: String)] = []
    for name in properties.keys {
      let location = child(child(pointer, "properties"), name)
      guard isIdentifier(name) else {
        throw failure(
          location,
          "Property name '\(name)' cannot be represented as a Swift tuple label; use an ASCII identifier."
        )
      }
      guard let property = node.children["properties/" + name] else {
        throw failure(location, "Missing resolved property schema.")
      }
      let generated = try plan(property)
      let isRequired = required.contains(name)
      expressions.append("""
        JSONProperty(key: \(swiftString(name))) {
        \(indent(generated.expression))
        }\(isRequired ? "\n.required()" : "")
        """)
      fields.append((name, generated.outputType + (isRequired ? "" : "?")))
    }
    guard !fields.isEmpty else {
      return GeneratedSchema(expression: "JSONObject()", outputType: "Void")
    }
    var expression = "JSONObject {\n\(indent(expressions.joined(separator: "\n")))\n}"
    let outputType: String
    if fields.count == 1 {
      outputType = fields[0].type
    } else {
      outputType = "(" + fields.map { "`\($0.name)`: \($0.type)" }.joined(separator: ", ") + ")"
      let values = fields.enumerated().map {
        let label = $0.element.name == "inout" ? "`inout`" : $0.element.name
        return "\(label): $0.\($0.offset)"
      }
      expression += "\n.map { (\(values.joined(separator: ", "))) }"
    }
    return GeneratedSchema(expression: expression, outputType: outputType)
  }

  private func schemaType(_ value: JSONValue?, at pointer: String) throws -> (String?, Bool) {
    guard let value else { return (nil, false) }
    if let type = value.string, Self.types.contains(type) { return (type, false) }
    if let values = value.array {
      let types = try values.enumerated().map { index, value in
        try string(value, at: child(pointer, String(index)))
      }
      guard !types.isEmpty, Set(types).count == types.count,
        types.allSatisfy(Self.types.contains)
      else {
        throw failure(pointer, "'type' must contain unique JSON Schema type names.")
      }
      if types.count == 1 { return (types[0], false) }
      if types.count == 2, types.contains("null"), let type = types.first(where: { $0 != "null" }) {
        return (type, true)
      }
      throw failure(pointer, "Only a single type or a union of one type with 'null' is supported.")
    }
    throw failure(pointer, "Expected a JSON Schema type name or a nullable type array.")
  }

  private func jsonLiteral(_ value: JSONValue, at pointer: String) throws -> String {
    switch value {
    case .string(let value): return ".string(\(swiftString(value)))"
    case .integer(let value): return ".integer(\(value))"
    case .number:
      return ".number(\(try finiteNumber(value, at: pointer)))"
    case .boolean(let value): return ".boolean(\(value))"
    case .null: return ".null"
    case .array(let values):
      return ".array([\(try values.map { try jsonLiteral($0, at: pointer) }.joined(separator: ", "))])"
    case .object(let values):
      if values.isEmpty { return ".object([:])" }
      let pairs = try values.map { key, value in
        "\(swiftString(key)): \(try jsonLiteral(value, at: child(pointer, key)))"
      }
      return ".object([\(pairs.joined(separator: ", "))])"
    }
  }

  private func string(_ value: JSONValue, at pointer: String) throws -> String {
    guard case .string(let text) = value else {
      throw failure(pointer, "Expected a string.")
    }
    return text
  }

  private func boolean(_ value: JSONValue, at pointer: String) throws -> Bool {
    guard case .boolean(let flag) = value else {
      throw failure(pointer, "Expected a boolean.")
    }
    return flag
  }

  private func finiteNumber(_ value: JSONValue, at pointer: String) throws -> Double {
    let number: Double
    switch value {
    case .integer(let integer): number = Double(integer)
    case .number(let double): number = double
    default: throw failure(pointer, "Expected a finite number.")
    }
    guard number.isFinite else { throw failure(pointer, "Expected a finite number.") }
    return number
  }

  private func nonnegativeInteger(_ value: JSONValue, at pointer: String) throws -> Int {
    if case .integer(let integer) = value, integer >= 0 { return integer }
    if case .number(let number) = value, let integer = Int(exactly: number), integer >= 0 {
      return integer
    }
    throw failure(pointer, "Expected a nonnegative integer representable by Swift.Int.")
  }

  private func swiftString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x20...0x7E: result.unicodeScalars.append(scalar)
      default: result += "\\u{\(String(scalar.value, radix: 16))}"
      }
    }
    return result + "\""
  }

  private func isIdentifier(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard value != "_", let first = scalars.first,
      Self.identifierStart.contains(first)
    else { return false }
    return scalars.dropFirst().allSatisfy(Self.identifierContinuation.contains)
  }

  private func child(_ pointer: String, _ key: String) -> String {
    pointer + "/" + key.replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
  }

  private func indent(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "  " + $0 }.joined(separator: "\n")
  }

  private func failure(_ pointer: String, _ message: String) -> SchemaGenerationError {
    SchemaGenerationError(pointer: pointer, message: message)
  }

  private static let identifierStart = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
  )
  private static let identifierContinuation = identifierStart.union(
    CharacterSet(charactersIn: "0123456789")
  )
  private static let types: Set<String> = [
    "string", "integer", "number", "boolean", "null", "object", "array",
  ]
  private static let nonnegativeIntegers: Set<String> = [
    "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
  ]
  private static let numericKeywords: Set<String> = [
    "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
  ]
  private static let keywordTypes: [String: Set<String>] = [
    "properties": ["object"], "required": ["object"], "additionalProperties": ["object"],
    "minProperties": ["object"], "maxProperties": ["object"],
    "items": ["array"], "minItems": ["array"], "maxItems": ["array"], "uniqueItems": ["array"],
    "minLength": ["string"], "maxLength": ["string"], "pattern": ["string"], "format": ["string"],
    "minimum": ["number", "integer"], "maximum": ["number", "integer"],
    "exclusiveMinimum": ["number", "integer"], "exclusiveMaximum": ["number", "integer"],
    "multipleOf": ["number", "integer"],
  ]
  private static let supportedKeywords = Set(keywordTypes.keys).union([
    "type", "enum", "const", "title", "description", "$comment", "$id", "$schema", "$anchor",
    "default", "examples", "readOnly", "writeOnly", "deprecated",
  ])
}
