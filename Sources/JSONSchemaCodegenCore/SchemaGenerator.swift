import Foundation
import OrderedJSON
import SwiftSyntax
import SwiftSyntaxBuilder

/// A source expression and the Swift value type it parses.
public struct GeneratedSchema: Equatable, Sendable {
  public let expression: String
  public let outputType: String
  /// Supporting type and helper declarations to place alongside the expression.
  public let declarations: [String]

  public init(expression: String, outputType: String, declarations: [String] = []) {
    self.expression = expression
    self.outputType = outputType
    self.declarations = declarations
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
    try generateSyntax(source).serialized()
  }

  package func generateSyntax(_ source: String) throws -> GeneratedSchemaSyntax {
    let graph = try SchemaReferenceGraph(
      documents: [
        SchemaDocument(source: source, retrievalURI: URL(fileURLWithPath: "/inline.schema.json"))
      ],
      includeDocumentURI: false
    )
    var emitter = SchemaEmitter()
    return try emitter.generate(graph.root(at: 0))
  }

  /// Generates a batch using a single registry, returning results in input order.
  ///
  /// Every input is registered before any reference is followed. Referenced files
  /// must be included in this array; URLs are identifiers, not fetch instructions.
  public func generate(_ documents: [SchemaDocument]) throws -> [GeneratedSchema] {
    let graph = try SchemaReferenceGraph(documents: documents)
    return try documents.indices.map {
      var emitter = SchemaEmitter()
      return try emitter.generate(graph.root(at: $0)).serialized()
    }
  }

  func generate(_ document: SchemaDocument, schemaPointers: [String]) throws -> [GeneratedSchema] {
    let graph = try SchemaReferenceGraph(documents: [document], schemaPointers: schemaPointers)
    return try schemaPointers.map {
      var emitter = SchemaEmitter()
      return try emitter.generate(graph.schema(at: $0)).serialized()
    }
  }
}

private struct SchemaEmitter {
  private var visitedNodes = 0
  private var declarations: [DeclSyntax] = []
  private var nextUnion = 0
  private var unionNames: [[SchemaOutput]: String] = [:]
  private var includesValidationHelper = false

  mutating func generate(_ node: ResolvedSchema) throws -> GeneratedSchemaSyntax {
    try checkSchema(node)
    let result = try plan(node)
    return try SchemaSyntax.finish(result, declarations: declarations, at: node)
  }

  mutating func plan(_ node: ResolvedSchema) throws -> SchemaFragment {
    do {
      visitedNodes += 1
      guard visitedNodes <= 10_000 else {
        throw failure(
          node.location.pointer, "Schema expansion exceeds the maximum of 10000 emitted nodes.")
      }
      if let simplified = inliningModifierRefinements(node) {
        return try plan(simplified)
      }
      if !node.refinements.isEmpty || node.value.object?["allOf"] != nil {
        return try applyingValidation(
          plan(intersection(conjuncts(node), at: node)), from: node
        )
      }
      if var object = node.value.object, let anyOf = object["anyOf"], object["oneOf"] != nil {
        object.removeValue(forKey: "anyOf")
        var first = node
        first.value = .object(object)
        var second = node
        second.value = .object(["anyOf": anyOf])
        let combined = ResolvedSchema(
          value: .object(["allOf": .array([first.value, second.value])]),
          location: node.location, documentURI: node.documentURI,
          children: ["allOf/0": first, "allOf/1": second]
        )
        return try applyingValidation(plan(combined), from: node)
      }
      for keyword in ["anyOf", "oneOf"] where node.value.object?[keyword] != nil {
        return try union(node, keyword: keyword)
      }
      if node.value.object?["not"] != nil {
        var base = node
        if var object = base.value.object {
          object.removeValue(forKey: "not")
          base.value = .object(object)
        }
        return try applyingValidation(plan(base), from: node)
      }
      return try emit(node)
    } catch let error as SchemaGenerationError {
      throw SchemaGenerationError(
        pointer: error.pointer, message: error.message,
        documentURI: error.documentURI ?? node.documentURI
      )
    }
  }

  private mutating func applyingValidation(
    _ generated: SchemaFragment, from node: ResolvedSchema
  ) throws -> SchemaFragment {
    let schema = try jsonLiteral(node.validationValue, at: node.location.pointer)
    if !includesValidationHelper {
      includesValidationHelper = true
      declarations.append(SchemaSyntax.validationHelper)
    }
    return SchemaFragment(
      expression: SchemaSyntax.call(
        SchemaSyntax.member(SchemaSyntax.reference("Self"), "_schemaWithDefinition"),
        [
          SchemaSyntax.argument(generated.expression),
          SchemaSyntax.argument(schema),
        ]),
      outputType: generated.outputType
    )
  }

  private mutating func union(_ node: ResolvedSchema, keyword: String) throws -> SchemaFragment {
    guard let branches = node.value.object?[keyword]?.array else {
      throw failure(node.location.pointer, "Missing composition branches.")
    }
    var outputs: [SchemaFragment] = []
    var sibling = node
    if var object = sibling.value.object {
      object.removeValue(forKey: keyword)
      sibling.value = .object(object)
    }
    for index in branches.indices {
      guard let branch = node.children["\(keyword)/\(index)"] else {
        throw failure(node.location.pointer, "Missing resolved composition branch.")
      }
      if ["properties", "required", "items"].contains(where: { sibling.value.object?[$0] != nil }) {
        let combined = ResolvedSchema(
          value: .object(["allOf": .array([sibling.value, branch.value])]),
          location: node.location, documentURI: node.documentURI,
          children: ["allOf/0": sibling, "allOf/1": branch]
        )
        outputs.append(try plan(combined))
      } else {
        outputs.append(try plan(branch))
      }
    }
    guard let first = outputs.first else {
      throw failure(node.location.pointer, "A union must have at least one branch.")
    }
    let outputType: SchemaOutput
    let body: [ExprSyntax]
    if outputs.allSatisfy({ $0.outputType == first.outputType }) {
      outputType = first.outputType
      body = outputs.map(\.expression)
    } else {
      // Identical union shapes share one nominal declaration within a namespace.
      let key = outputs.map(\.outputType)
      if let existing = unionNames[key] {
        outputType = .named(existing)
      } else {
        nextUnion += 1
        let name = "Union\(nextUnion)"
        outputType = .named(name)
        unionNames[key] = name
        declarations.append(SchemaSyntax.unionDeclaration(name, outputs: key))
      }
      body = outputs.enumerated().map {
        SchemaSyntax.unionMap(
          $0.element.expression, input: $0.element.outputType.syntax,
          output: outputType.syntax, index: $0.offset
        )
      }
    }
    let name = keyword == "oneOf" ? "OneOf" : "AnyOf"
    let branchBody: [ExprSyntax]
    // Explicit arrays disambiguate JSONValue builder overloads and adjacent IIFEs.
    if outputType == "JSONValue"
      || body.contains(where: {
        $0.firstToken(viewMode: .sourceAccurate)?.tokenKind == .leftBrace
      })
    {
      let erasedBranches = body.map {
        SchemaSyntax.call(
          SchemaSyntax.member(
            ExprSyntax(TupleExprSyntax(elements: [SchemaSyntax.argument($0)])),
            "eraseToAnySchemaComponent"
          ))
      }
      branchBody = [SchemaSyntax.array(erasedBranches, multiline: true)]
    } else {
      branchBody = body.enumerated().map {
        $0.element.with(\.leadingTrivia, $0.offset == 0 ? [] : .newline)
      }
    }
    let generated = SchemaFragment(
      expression: SchemaSyntax.call(
        SchemaSyntax.member(SchemaSyntax.reference("JSONComposition"), name),
        [SchemaSyntax.argument(SchemaSyntax.metatype(outputType.syntax), label: "into")],
        body: branchBody
      ),
      outputType: outputType
    )
    if let keys = sibling.value.object?.keys,
      keys.allSatisfy(Self.commonModifierKeywords.contains)
    {
      return SchemaFragment(
        expression: try applyingCommonModifiers(to: generated.expression, from: sibling),
        outputType: outputType
      )
    }
    return try applyingValidation(generated, from: node)
  }

  private func inliningModifierRefinements(_ node: ResolvedSchema) -> ResolvedSchema? {
    guard !node.refinements.isEmpty, var object = node.value.object else { return nil }
    for refinement in node.refinements {
      guard refinement.refinements.isEmpty, let modifiers = refinement.value.object,
        modifiers.keys.allSatisfy(Self.commonModifierKeywords.contains),
        modifiers.keys.allSatisfy({ object[$0] == nil })
      else { return nil }
      // Repeated keywords must remain separate conjunctions, not overwrite each other.
      for (key, value) in modifiers { object[key] = value }
    }
    var result = node
    result.value = .object(object)
    result.refinements = []
    return result
  }

  private func conjuncts(_ node: ResolvedSchema) -> [ResolvedSchema] {
    var base = node
    base.refinements = []
    var result: [ResolvedSchema] = []
    if var object = base.value.object, let branches = object.removeValue(forKey: "allOf")?.array {
      base.value = .object(object)
      for index in branches.indices {
        if let branch = node.children["allOf/\(index)"] { result += conjuncts(branch) }
      }
    }
    return [base] + result + node.refinements.flatMap(conjuncts)
  }

  /// Build only the parsing projection. Validation uses the original conjunction,
  /// so closed objects and repeated constraints never acquire merge semantics.
  private func intersection(_ nodes: [ResolvedSchema], at location: ResolvedSchema) throws
    -> ResolvedSchema
  {
    let nodes = nodes.filter { $0.value != .boolean(true) && $0.value != .object([:]) }
    if nodes.contains(where: { $0.value == .boolean(false) }) {
      return ResolvedSchema(
        value: .boolean(false), location: location.location, documentURI: location.documentURI)
    }
    let unionIndex = nodes.firstIndex {
      $0.value.object?["anyOf"] != nil || $0.value.object?["oneOf"] != nil
    }
    if let unionIndex {
      let union = nodes[unionIndex]
      let keyword = union.value.object?["oneOf"] != nil ? "oneOf" : "anyOf"
      guard let branches = union.value.object?[keyword]?.array else {
        throw failure(union.location.pointer, "Missing union branches.")
      }
      var siblings = nodes
      siblings.remove(at: unionIndex)
      var ownSiblings = union
      if var object = ownSiblings.value.object {
        object.removeValue(forKey: keyword)
        ownSiblings.value = .object(object)
      }
      if ownSiblings.value != .object([:]) { siblings.append(ownSiblings) }
      guard !siblings.isEmpty else { return union }
      var projected = ResolvedSchema(
        value: .object([keyword: .array(branches)]),
        location: union.location, documentURI: union.documentURI
      )
      for index in branches.indices {
        guard let branch = union.children["\(keyword)/\(index)"] else {
          throw failure(union.location.pointer, "Missing resolved union branch.")
        }
        let constraints = [branch] + siblings
        projected.children["\(keyword)/\(index)"] = ResolvedSchema(
          value: .object(["allOf": .array(constraints.map(\.value))]),
          location: branch.location, documentURI: branch.documentURI,
          children: Dictionary(
            uniqueKeysWithValues: constraints.enumerated().map {
              ("allOf/\($0.offset)", $0.element)
            })
        )
      }
      return projected
    }
    var domain: Set<String>?
    for node in nodes {
      if let type = node.value.object?["type"] {
        let (name, nullable) = try schemaType(type, at: node.location.child("type").pointer)
        var types: Set<String> = [name ?? ""]
        if name == "number" { types.insert("integer") }
        if nullable { types.insert("null") }
        domain = domain.map { $0.intersection(types) } ?? types
      }
    }
    guard var domain else {
      return ResolvedSchema(
        value: .object([:]), location: location.location, documentURI: location.documentURI)
    }
    if domain.isEmpty {
      return ResolvedSchema(
        value: .boolean(false), location: location.location, documentURI: location.documentURI)
    }
    if domain.contains("number") { domain.remove("integer") }
    let nullable = domain.count > 1 && domain.contains("null")
    let type = domain.first(where: { $0 != "null" }) ?? "null"
    var projection = ResolvedSchema(
      value: .object(["type": nullable ? .array([.string(type), .string("null")]) : .string(type)]),
      location: location.location, documentURI: location.documentURI
    )
    if type == "object" {
      var properties = JSONValue.object([:])
      var required: [JSONValue] = []
      var fields: [String: [ResolvedSchema]] = [:]
      var order: [String] = []
      for node in nodes {
        if let object = node.value.object?["properties"]?.object {
          for name in object.keys {
            if fields[name] == nil { order.append(name) }
            if let field = node.children["properties/" + name] {
              fields[name, default: []].append(field)
            }
          }
        }
        for key in node.value.object?["required"]?.array ?? [] where !required.contains(key) {
          required.append(key)
        }
      }
      for key in required.compactMap(\.string) where fields[key] == nil {
        order.append(key)
        fields[key] = [
          ResolvedSchema(
            value: .object([:]), location: location.location, documentURI: location.documentURI)
        ]
      }
      for name in order {
        guard let variants = fields[name], let first = variants.first else { continue }
        var field = first
        if variants.count > 1 {
          field = ResolvedSchema(
            value: .object(["allOf": .array(variants.map(\.value))]),
            location: first.location, documentURI: first.documentURI,
            children: Dictionary(
              uniqueKeysWithValues: variants.enumerated().map { ("allOf/\($0.offset)", $0.element) }
            )
          )
        }
        if var object = properties.object {
          object[name] = field.value
          properties = .object(object)
        }
        projection.children["properties/" + name] = field
      }
      projection.value = .object([
        "type": nullable ? .array([.string("object"), .string("null")]) : .string("object"),
        "properties": properties, "required": .array(required),
      ])
    } else if type == "array" {
      let items = nodes.compactMap { $0.children["items"] }
      if let first = items.first {
        let item =
          items.count == 1
          ? first
          : ResolvedSchema(
            value: .object(["allOf": .array(items.map(\.value))]),
            location: first.location, documentURI: first.documentURI,
            children: Dictionary(
              uniqueKeysWithValues: items.enumerated().map { ("allOf/\($0.offset)", $0.element) })
          )
        projection.children["items"] = item
        if var object = projection.value.object {
          object["items"] = item.value
          projection.value = .object(object)
        }
      }
    }
    return projection
  }

  /// Validate every reachable keyword, including branches used only for validation
  /// rather than parsing. Projection must never hide unsupported input.
  private func checkSchema(_ node: ResolvedSchema) throws {
    do {
      for refinement in node.refinements { try checkSchema(refinement) }
      guard let object = node.value.object else {
        guard node.value.boolean != nil else {
          throw failure(node.location.pointer, "Expected a schema object or boolean.")
        }
        return
      }
      for (key, value) in object {
        let pointer = node.location.child(key).pointer
        guard Self.supportedKeywords.contains(key) else {
          throw failure(pointer, "Unsupported keyword '\(key)'.")
        }
        if Self.nonnegativeIntegers.contains(key) {
          _ = try nonnegativeInteger(value, at: pointer)
        } else if Self.numericKeywords.contains(key) {
          let number = try finiteNumber(value, at: pointer)
          if key == "multipleOf", number <= 0 {
            throw failure(pointer, "'multipleOf' must be greater than zero.")
          }
        } else {
          switch key {
          case "type": _ = try schemaType(value, at: pointer)
          case "title", "description", "$comment", "$id", "$schema", "$anchor", "format":
            _ = try string(value, at: pointer)
          case "pattern":
            let pattern = try string(value, at: pointer)
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
              throw failure(pointer, "Invalid regular expression: \(error.localizedDescription)")
            }
          case "readOnly", "writeOnly", "deprecated", "uniqueItems":
            _ = try boolean(value, at: pointer)
          case "additionalProperties":
            guard value.boolean != nil else {
              throw failure(
                pointer,
                "Schema-valued additional properties are not yet supported; expected a boolean.")
            }
          case "required":
            guard let keys = value.array else {
              throw failure(pointer, "'required' must be an array of unique property names.")
            }
            let strings = try keys.map { try string($0, at: pointer) }
            guard Set(strings).count == strings.count else {
              throw failure(pointer, "'required' must contain unique property names.")
            }
          case "properties":
            if let properties = value.object {
              for name in properties.keys where !isIdentifier(name) {
                throw failure(
                  node.location.child("properties").child(name).pointer,
                  "Property name '\(name)' cannot be represented as a Swift tuple label; use an ASCII identifier."
                )
              }
            }
          case "enum":
            guard let cases = value.array, !cases.isEmpty else {
              throw failure(pointer, "'enum' must be a nonempty array.")
            }
            guard Set(cases).count == cases.count else {
              throw failure(pointer, "'enum' values must be unique.")
            }
          case "examples":
            guard value.array != nil else { throw failure(pointer, "'examples' must be an array.") }
          default: break
          }
        }
      }
      for key in node.children.keys.sorted() {
        if let child = node.children[key] { try checkSchema(child) }
      }
    } catch let error as SchemaGenerationError {
      throw SchemaGenerationError(
        pointer: error.pointer, message: error.message,
        documentURI: error.documentURI ?? node.documentURI
      )
    }
  }

  private mutating func emit(_ node: ResolvedSchema) throws -> SchemaFragment {
    let value = node.value
    let pointer = node.location.pointer
    if case .boolean(let flag) = value {
      return SchemaFragment(
        expression: SchemaSyntax.call(
          SchemaSyntax.member(SchemaSyntax.reference("JSONComponents"), "PassthroughComponent"),
          [
            SchemaSyntax.argument(
              SchemaSyntax.call(
                SchemaSyntax.reference("JSONBooleanSchema"),
                [
                  SchemaSyntax.argument(ExprSyntax(literal: flag), label: "booleanLiteral")
                ]), label: "wrapped"
            )
          ]
        ),
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
    var expression: ExprSyntax
    var outputType: SchemaOutput
    switch type {
    case "string":
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONString"))
      outputType = "String"
    case "integer":
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONInteger"))
      outputType = "Int"
    case "number":
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONNumber"))
      outputType = "Double"
    case "boolean":
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONBoolean"))
      outputType = "Bool"
    case "null":
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONNull"))
      outputType = "Void"
    case "object":
      let generated = try objectPlan(node)
      expression = generated.expression
      outputType = generated.outputType
    case "array":
      let itemNode =
        node.children["items"]
        ?? ResolvedSchema(
          value: .object([:]), location: node.location.child("items"), documentURI: node.documentURI
        )
      let items = try plan(itemNode)
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONArray"), body: [items.expression])
      outputType = .array(items.outputType)
      // The upstream array initializer only copies object-shaped item schemas.
      if case .boolean(let flag) = itemNode.value, itemNode.refinements.isEmpty {
        expression = SchemaSyntax.booleanArray(expression, flag: flag)
      }
    default:
      expression = SchemaSyntax.call(SchemaSyntax.reference("JSONAnyValue"))
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
        expression = SchemaSyntax.modifier(
          expression, key, [SchemaSyntax.argument(ExprSyntax(literal: number))])
      } else if Self.numericKeywords.contains(key) {
        let number = try finiteNumber(keyword, at: location)
        if key == "multipleOf", number <= 0 {
          throw failure(location, "'multipleOf' must be greater than zero.")
        }
        expression = SchemaSyntax.modifier(
          expression, key, [SchemaSyntax.argument(ExprSyntax(literal: number))])
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
          expression = SchemaSyntax.modifier(
            expression, key, [SchemaSyntax.argument(SchemaSyntax.stringLiteral(text))])
        case "additionalProperties", "uniqueItems":
          if key == "additionalProperties", keyword.boolean == nil {
            throw failure(
              location,
              "Schema-valued additional properties are not yet supported; expected a boolean.")
          }
          expression = SchemaSyntax.modifier(
            expression, key,
            [
              SchemaSyntax.argument(ExprSyntax(literal: try boolean(keyword, at: location)))
            ])
        default:
          break
        }
      }
    }

    expression = try applyingCommonModifiers(to: expression, from: node)
    if nullable {
      expression = SchemaSyntax.modifier(
        expression, "orNull",
        [
          SchemaSyntax.argument(SchemaSyntax.member("type"), label: "style")
        ])
      outputType = .optional(outputType)
    }
    return SchemaFragment(expression: expression, outputType: outputType)
  }

  private func applyingCommonModifiers(to source: ExprSyntax, from node: ResolvedSchema) throws
    -> ExprSyntax
  {
    guard let object = node.value.object else {
      throw failure(node.location.pointer, "Expected an object schema for modifiers.")
    }
    var expression = source
    for (key, keyword) in object {
      let location = node.location.child(key).pointer
      switch key {
      case "title", "description", "$comment", "$id", "$schema", "$anchor":
        let text = try string(keyword, at: location)
        if key == "$schema", text != "https://json-schema.org/draft/2020-12/schema" {
          throw failure(location, "Only the JSON Schema 2020-12 dialect is supported.")
        }
        let method =
          ["$comment": "comment", "$id": "id", "$schema": "schema", "$anchor": "anchor"][key] ?? key
        expression = SchemaSyntax.modifier(
          expression, method, [SchemaSyntax.argument(SchemaSyntax.stringLiteral(text))])
      case "readOnly", "writeOnly", "deprecated":
        expression = SchemaSyntax.modifier(
          expression, key,
          [
            SchemaSyntax.argument(ExprSyntax(literal: try boolean(keyword, at: location)))
          ])
      case "default", "const":
        let method = key == "const" ? "constant" : "`default`"
        expression = SchemaSyntax.modifier(
          expression, method,
          [
            SchemaSyntax.argument(try jsonLiteral(keyword, at: location))
          ])
      case "examples":
        guard keyword.array != nil else {
          throw failure(location, "'examples' must be an array.")
        }
        expression = SchemaSyntax.modifier(
          expression, "examples",
          [
            SchemaSyntax.argument(try jsonLiteral(keyword, at: location))
          ])
      default:
        break
      }
    }
    if let keyword = object["enum"] {
      let location = node.location.child("enum").pointer
      guard let values = keyword.array, !values.isEmpty else {
        throw failure(location, "'enum' must be a nonempty array.")
      }
      guard Set(values).count == values.count else {
        throw failure(location, "'enum' values must be unique.")
      }
      expression = SchemaSyntax.call(
        SchemaSyntax.member(SchemaSyntax.reference("JSONComponents"), "Enum"),
        [
          SchemaSyntax.argument(expression, label: "upstream"),
          SchemaSyntax.argument(
            SchemaSyntax.array(try values.map { try jsonLiteral($0, at: location) }),
            label: "cases"
          ),
        ]
      )
    }
    return expression
  }

  private mutating func objectPlan(_ node: ResolvedSchema) throws -> SchemaFragment {
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
    var expressions: [ExprSyntax] = []
    var fields: [SchemaOutput.Field] = []
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
      let expression = SchemaSyntax.call(
        SchemaSyntax.reference("JSONProperty"),
        [SchemaSyntax.argument(SchemaSyntax.stringLiteral(name), label: "key")],
        body: [generated.expression]
      )
      expressions.append(isRequired ? SchemaSyntax.modifier(expression, "required") : expression)
      fields.append(
        .init(
          name: name, type: isRequired ? generated.outputType : .optional(generated.outputType)
        ))
    }
    guard !fields.isEmpty else {
      return SchemaFragment(
        expression: SchemaSyntax.call(SchemaSyntax.reference("JSONObject")), outputType: "Void"
      )
    }
    var expression = SchemaSyntax.call(SchemaSyntax.reference("JSONObject"), body: expressions)
    let outputType: SchemaOutput
    if fields.count == 1 {
      outputType = fields[0].type
    } else {
      outputType = .tuple(fields)
      expression = SchemaSyntax.tupleMap(expression, fields: fields)
    }
    return SchemaFragment(expression: expression, outputType: outputType)
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

  private func jsonLiteral(_ value: JSONValue, at pointer: String) throws -> ExprSyntax {
    switch value {
    case .string(let value):
      return SchemaSyntax.call(
        SchemaSyntax.member("string"), [SchemaSyntax.argument(SchemaSyntax.stringLiteral(value))])
    case .integer(let value):
      return SchemaSyntax.call(
        SchemaSyntax.member("integer"), [SchemaSyntax.argument(ExprSyntax(literal: value))])
    case .number:
      return SchemaSyntax.call(
        SchemaSyntax.member("number"),
        [
          SchemaSyntax.argument(ExprSyntax(literal: try finiteNumber(value, at: pointer)))
        ])
    case .boolean(let value):
      return SchemaSyntax.call(
        SchemaSyntax.member("boolean"), [SchemaSyntax.argument(ExprSyntax(literal: value))])
    case .null: return SchemaSyntax.member("null")
    case .array(let values):
      return SchemaSyntax.call(
        SchemaSyntax.member("array"),
        [
          SchemaSyntax.argument(
            SchemaSyntax.array(try values.map { try jsonLiteral($0, at: pointer) }))
        ])
    case .object(let values):
      let pairs = try values.map { key, value in
        (SchemaSyntax.stringLiteral(key), try jsonLiteral(value, at: child(pointer, key)))
      }
      return SchemaSyntax.call(
        SchemaSyntax.member("object"),
        [
          SchemaSyntax.argument(SchemaSyntax.dictionary(pairs))
        ])
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

  private func isIdentifier(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard value != "_", let first = scalars.first,
      Self.identifierStart.contains(first)
    else { return false }
    return scalars.dropFirst().allSatisfy(Self.identifierContinuation.contains)
  }

  private func child(_ pointer: String, _ key: String) -> String {
    pointer + "/"
      + key.replacingOccurrences(of: "~", with: "~0")
      .replacingOccurrences(of: "/", with: "~1")
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
  private static let commonModifierKeywords: Set<String> = [
    "title", "description", "$comment", "$id", "$schema", "$anchor",
    "default", "examples", "readOnly", "writeOnly", "deprecated", "enum", "const",
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
  private static let supportedKeywords = Set(keywordTypes.keys)
    .union(commonModifierKeywords)
    .union(["type", "allOf", "anyOf", "oneOf", "not"])
}
