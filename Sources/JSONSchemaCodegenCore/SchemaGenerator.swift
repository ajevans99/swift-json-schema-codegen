import Foundation
import JSONSchemaCodegenConfiguration
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
/// explicitly supplied document registry. Unknown keywords are retained as
/// annotations; unknown required vocabularies are rejected.
public struct SchemaGenerator: Sendable {
  public let options: SchemaGenerationOptions

  public init(options: SchemaGenerationOptions = .init()) {
    self.options = options
  }

  public func generate(_ source: String) throws -> GeneratedSchema {
    try generateSyntax(source).serialized()
  }

  package func generateSyntax(_ source: String, namespaceName: String? = nil) throws
    -> GeneratedSchemaSyntax
  {
    let graph = try SchemaReferenceGraph(
      documents: [
        SchemaDocument(
          source: source, retrievalURI: URL(fileURLWithPath: "/inline.schema.json"),
          logicalName: "inline.schema.json")
      ],
      includeDocumentURI: false
    )
    var emitter = SchemaEmitter(options: options, namespace: namespaceName)
    return try emitter.generate(graph.root(at: 0))
  }

  /// Generates a batch using a single registry, returning results in input order.
  ///
  /// Every input is registered before any reference is followed. Referenced files
  /// must be included in this array; URLs are identifiers, not fetch instructions.
  public func generate(_ documents: [SchemaDocument]) throws -> [GeneratedSchema] {
    let graph = try SchemaReferenceGraph(documents: documents)
    return try generate(roots: documents.indices.map { try graph.root(at: $0) })
  }

  private func generate(roots: [ResolvedSchema]) throws -> [GeneratedSchema] {
    var usedTypes = Set<String>()
    var usedCases = Set<String>()
    let result = try roots.map { root in
      var emitter = SchemaEmitter(options: options, allowsUnmatchedOverrides: true)
      let result = try emitter.generate(root).serialized()
      usedTypes.formUnion(emitter.usedTypeOverrides)
      usedCases.formUnion(emitter.usedCaseOverrides)
      return result
    }
    for (kind, table, used) in [
      ("type", options.names.typeNames, usedTypes), ("case", options.names.caseNames, usedCases),
    ] {
      if let key = Set(table.keys).subtracting(used).sorted().first {
        throw SchemaGenerationError(
          pointer: key,
          message: "The \(kind)-name override '\(key)' does not resolve to an emitted \(kind).")
      }
    }
    return result
  }

  /// Generates one entry point using an explicitly supplied offline reference registry.
  public func generate(
    _ document: SchemaDocument, referencing documents: [SchemaDocument]
  ) throws -> GeneratedSchema {
    let graph = try SchemaReferenceGraph(documents: [document] + documents)
    var emitter = SchemaEmitter(options: options)
    return try emitter.generate(graph.root(at: 0)).serialized()
  }

  func generate(_ document: SchemaDocument, schemaPointers: [String]) throws -> [GeneratedSchema] {
    let graph = try SchemaReferenceGraph(documents: [document], schemaPointers: schemaPointers)
    return try generate(roots: schemaPointers.map { try graph.schema(at: $0) })
  }
}

private struct SchemaEmitter {
  let options: SchemaGenerationOptions
  var namespace: String? = nil
  private var models = SchemaModelGraph()
  private var referenceDefinitions: [String: ResolvedSchema] = [:]
  private var specializedReferences: [String: String] = [:]
  private var usedReferences = Set<String>()
  private var visitedNodes = 0
  private var declarations: [DeclSyntax] = []
  private var nextUnion = 0
  private var unionNames: [[SchemaOutput]: String] = [:]
  private var includesValidationHelper = false
  private let allowsUnmatchedOverrides: Bool
  private(set) var usedTypeOverrides = Set<String>()
  private(set) var usedCaseOverrides = Set<String>()

  init(
    options: SchemaGenerationOptions, namespace: String? = nil,
    allowsUnmatchedOverrides: Bool = false
  ) {
    self.options = options
    self.namespace = namespace
    self.allowsUnmatchedOverrides = allowsUnmatchedOverrides
  }

  mutating func generate(_ node: ResolvedSchema) throws -> GeneratedSchemaSyntax {
    if options.output == .tuples,
      !options.names.typeNames.isEmpty || !options.names.caseNames.isEmpty
    {
      throw failure(node.location.pointer, "Name overrides require output: .models.")
    }
    try checkSchema(node)
    for name in node.recursiveDefinitions.keys.sorted() {
      if let definition = node.recursiveDefinitions[name] { try checkSchema(definition) }
    }
    referenceDefinitions = node.recursiveDefinitions
    usedReferences = options.output == .models ? [] : Set(referenceDefinitions.keys)
    var result = try plan(node)
    var emittedReferences = Set<String>()
    while let name = usedReferences.subtracting(emittedReferences).sorted().first {
      guard let definition = referenceDefinitions[name] else {
        throw failure(node.location.pointer, "Missing recursive definition '\(name)'.")
      }
      emittedReferences.insert(name)
      let fragment = try plan(definition)
      var complete = definition
      complete.recursiveDefinitions = node.recursiveDefinitions
      let validated = try applyingValidation(fragment, from: complete)
      if options.output == .models {
        models.referenceOutputs[name] = fragment.outputType
        models.referenceProvenances[name] = SchemaModelGraph.provenance(definition)
        declarations.append(
          SchemaSyntax.modelRecursiveDeclaration(name, output: fragment.outputType))
        declarations.append(
          SchemaSyntax.modelRecursiveFactory(name, expression: validated.expression))
      } else {
        declarations.append(SchemaSyntax.recursiveDeclaration(name, output: fragment.outputType))
        declarations.append(SchemaSyntax.recursiveFactory(name, expression: validated.expression))
      }
    }
    if !node.recursiveDefinitions.isEmpty {
      result = try applyingValidation(result, from: node)
    }
    if options.output == .models {
      models.root = result.outputType
      models.rootProvenance = SchemaModelGraph.provenance(node)
      let layout = try SchemaModelLayout(graph: models, strategy: options.recursiveObjects)
      let allocation = try SchemaModelAllocation(
        graph: models, options: options, namespace: namespace,
        allowsUnmatchedOverrides: allowsUnmatchedOverrides)
      usedTypeOverrides = allocation.usedTypeOverrides
      usedCaseOverrides = allocation.usedCaseOverrides
      let typeRewriter = SchemaModelRewriter(
        names: allocation.names, cases: allocation.cases, references: [:])
      let references = try models.referenceOutputs.mapValues {
        typeRewriter.rewrite(try models.resolving($0).syntax).cast(TypeSyntax.self)
      }
      let rewriter = SchemaModelRewriter(
        names: allocation.names, cases: allocation.cases,
        references: Dictionary(
          uniqueKeysWithValues: references.map {
            (SchemaModelNames.helperPrefix + "Output" + $0.key, $0.value)
          }))
      declarations =
        try SchemaModelSyntax.declarations(
          graph: models, names: allocation.names, cases: allocation.cases, layout: layout
        ) + declarations.map { rewriter.rewrite($0).cast(DeclSyntax.self) }
      result = SchemaFragment(
        expression: rewriter.rewrite(result.expression).cast(ExprSyntax.self),
        outputType: .named("Value"))
    }
    return try SchemaSyntax.finish(result, declarations: declarations, at: node)
  }

  mutating func plan(_ node: ResolvedSchema) throws -> SchemaFragment {
    do {
      visitedNodes += 1
      guard visitedNodes <= 10_000 else {
        throw failure(
          node.location.pointer, "Schema expansion exceeds the maximum of 10000 emitted nodes.")
      }
      if let reference = node.reference {
        if options.output == .models, !node.refinements.isEmpty,
          node.refinements.contains(where: { refinement in
            refinement.value.object?.keys.contains(where: {
              [
                "type", "properties", "required", "items", "prefixItems",
                "additionalProperties", "allOf", "anyOf", "oneOf",
              ].contains($0)
            }) == true
          }),
          let target = referenceDefinitions[reference]
        {
          let identity = SchemaModelGraph.provenance(node).identity
          let adapter: String
          if let existing = specializedReferences[identity] {
            adapter = existing
          } else {
            adapter = "Specialization\(specializedReferences.count + 1)"
            specializedReferences[identity] = adapter
            var definition = target
            definition.refinements += node.refinements
            definition.referenceApplication = node.referenceApplication
            definition.modelProvenance = node.modelProvenance
            referenceDefinitions[adapter] = definition
          }
          usedReferences.insert(adapter)
          return try applyingValidation(
            SchemaFragment(
              expression: SchemaSyntax.modelRecursiveReference(adapter, uriName: reference),
              outputType: .recursive(adapter)),
            from: node)
        }
        if options.output == .models { usedReferences.insert(reference) }
        let fragment = SchemaFragment(
          expression: options.output == .models
            ? SchemaSyntax.modelRecursiveReference(reference)
            : SchemaSyntax.recursiveReference(reference),
          outputType: options.output == .models ? .recursive(reference) : .named(reference))
        return node.refinements.isEmpty
          ? fragment : try applyingValidation(fragment, from: node)
      }
      if let simplified = inliningModifierRefinements(node) {
        return try plan(simplified)
      }
      if !node.refinements.isEmpty || node.value.object?["allOf"] != nil {
        var projection = try intersection(conjuncts(node), at: node)
        projection.modelProvenance = node.modelProvenance
        return try applyingValidation(
          plan(projection), from: node
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
          children: ["allOf/0": first, "allOf/1": second],
          modelProvenance: node.modelProvenance
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
      if let types = try schemaTypes(
        node.value.object?["type"], at: node.location.child("type").pointer),
        types.count > 2 || (types.count == 2 && !types.contains("null"))
      {
        var projection = node
        projection.value = .object(["anyOf": .array(types.map { .object(["type": .string($0)]) })])
        for (index, type) in types.enumerated() {
          var branch = node
          if var object = branch.value.object {
            object["type"] = .string(type)
            branch.value = .object(object)
          }
          if options.output == .models {
            let provenance = SchemaModelGraph.provenance(node)
            branch.modelProvenance = .init(
              identity: provenance.identity + "|type:" + type,
              origins: provenance.origins.map {
                .init(
                  pointer: $0.pointer + "/type/\(index)", documentURI: $0.documentURI,
                  logicalDocument: $0.logicalDocument, resource: $0.resource + "/type/\(index)")
              })
          }
          projection.children["anyOf/\(index)"] = branch
        }
        return try applyingValidation(union(projection, keyword: "anyOf"), from: node)
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
    var branchSchemas: [ResolvedSchema] = []
    var sibling = node
    if var object = sibling.value.object {
      object.removeValue(forKey: keyword)
      sibling.value = .object(object)
    }
    let parsingSibling = removingUnevaluatedKeywords(sibling)
    for index in branches.indices {
      guard let branch = node.children["\(keyword)/\(index)"] else {
        throw failure(node.location.pointer, "Missing resolved composition branch.")
      }
      if ["properties", "required", "items"].contains(where: { sibling.value.object?[$0] != nil })
        || (options.output == .models && sibling.value.object?["type"] != nil)
      {
        let combined = ResolvedSchema(
          value: .object(["allOf": .array([parsingSibling.value, branch.value])]),
          location: node.location, documentURI: node.documentURI,
          children: ["allOf/0": parsingSibling, "allOf/1": branch],
          modelProvenance: SchemaModelGraph.specialization(
            of: node, path: [keyword, String(index)], constraints: [parsingSibling, branch])
        )
        outputs.append(try plan(combined))
        branchSchemas.append(try intersection(conjuncts(combined), at: branch))
      } else {
        outputs.append(try plan(branch))
        branchSchemas.append(branch)
      }
    }
    guard !outputs.isEmpty else {
      throw failure(node.location.pointer, "A union must have at least one branch.")
    }
    let unionPlan = SchemaParsingPlan.Union(branches: outputs)
    let outputType: SchemaOutput
    let body: [ExprSyntax]
    if let common = unionPlan.commonOutput {
      outputType = common
      body = outputs.map(\.expression)
    } else if options.output == .models, let null = unionPlan.nullableBranch {
      outputType = .optional(outputs[1 - null].outputType)
      body = outputs.enumerated().map { index, fragment in
        SchemaModelSyntax.map(
          fragment.expression, to: outputType,
          value: index == null
            ? ExprSyntax(NilLiteralExprSyntax())
            : SchemaSyntax.call(
              SchemaSyntax.member("some"),
              [
                SchemaSyntax.argument(SchemaSyntax.reference(SchemaModelSyntax.parsedValueName))
              ]))
      }
    } else if options.output == .models {
      let (model, branches) = models.union(
        at: node, keyword: keyword, outputs: outputs, schemas: branchSchemas)
      outputType = model
      body = outputs.enumerated().map { index, fragment in
        SchemaModelSyntax.unionMap(
          fragment.expression, output: model, branch: branches[index],
          null: fragment.outputType == .named("Void"))
      }
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
    base.referenceApplication = nil
    if !node.refinements.isEmpty || node.value.object?["allOf"] != nil {
      base = removingUnevaluatedKeywords(base)
    }
    var result: [ResolvedSchema] = []
    if var object = base.value.object, let branches = object.removeValue(forKey: "allOf")?.array {
      base.value = .object(object)
      for index in branches.indices {
        if let branch = node.children["allOf/\(index)"] { result += conjuncts(branch) }
      }
    }
    return [base] + result + node.refinements.flatMap(conjuncts)
  }

  private func removingUnevaluatedKeywords(_ node: ResolvedSchema) -> ResolvedSchema {
    var result = node
    if var object = result.value.object {
      // Complete-schema validation consumes annotations before parsing branches.
      object.removeValue(forKey: "unevaluatedProperties")
      object.removeValue(forKey: "unevaluatedItems")
      result.value = .object(object)
    }
    return result
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
      var ownSiblings = removingUnevaluatedKeywords(union)
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
            }),
          modelProvenance: SchemaModelGraph.specialization(
            of: location, path: [keyword, String(index)], constraints: constraints)
        )
      }
      return projected
    }
    var domain: Set<String>?
    for node in nodes {
      if let type = node.value.object?["type"] {
        var types = Set(try schemaTypes(type, at: node.location.child("type").pointer) ?? [])
        if types.contains("number") { types.insert("integer") }
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
    if domain.count > 2 || (domain.count == 2 && !domain.contains("null")) {
      let orderedTypes = Self.typeOrder.filter(domain.contains)
      var union = ResolvedSchema(
        value: .object(["anyOf": .array(orderedTypes.map { .object(["type": .string($0)]) })]),
        location: location.location, documentURI: location.documentURI
      )
      for (index, type) in orderedTypes.enumerated() {
        let typeNode = ResolvedSchema(
          value: .object(["type": .string(type)]),
          location: location.location, documentURI: location.documentURI
        )
        union.children["anyOf/\(index)"] = try intersection(nodes + [typeNode], at: location)
      }
      return union
    }
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
      for name in order {
        guard let variants = fields[name], let first = variants.first else { continue }
        var field = first
        if variants.count > 1 {
          field = ResolvedSchema(
            value: .object(["allOf": .array(variants.map(\.value))]),
            location: first.location, documentURI: first.documentURI,
            children: Dictionary(
              uniqueKeysWithValues: variants.enumerated().map { ("allOf/\($0.offset)", $0.element) }
            ),
            modelProvenance: SchemaModelGraph.specialization(
              of: location, path: ["properties", name], constraints: variants)
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
      var object = projection.value.object ?? [:]
      var patterns = JSONValue.object([:])
      for node in nodes {
        for name in node.value.object?["patternProperties"]?.object.map({ Array($0.keys) }) ?? [] {
          if var entries = patterns.object {
            entries[name] = .boolean(true)
            patterns = .object(entries)
          }
        }
      }
      if patterns.object?.isEmpty == false { object["patternProperties"] = patterns }
      if nodes.contains(where: { $0.value.object?["additionalProperties"]?.object != nil }) {
        let variants = nodes.compactMap { $0.children["additionalProperties"] }
        if let first = variants.first {
          let additional =
            variants.count == 1
            ? first
            : ResolvedSchema(
              value: .object(["allOf": .array(variants.map(\.value))]),
              location: first.location, documentURI: first.documentURI,
              children: Dictionary(
                uniqueKeysWithValues: variants.enumerated().map {
                  ("allOf/\($0.offset)", $0.element)
                }
              ),
              modelProvenance: SchemaModelGraph.specialization(
                of: location, path: ["additionalProperties"], constraints: variants)
            )
          object["additionalProperties"] = additional.value
          projection.children["additionalProperties"] = additional
        }
      }
      projection.value = .object(object)
    } else if type == "array" {
      if let prefix = nodes.first(where: { $0.value.object?["prefixItems"] != nil }) {
        // A heterogeneous prefix must not be parsed through the tail's item type.
        if var object = projection.value.object {
          object["prefixItems"] = prefix.value.object?["prefixItems"]
          projection.value = .object(object)
        }
        for (key, child) in prefix.children where key.hasPrefix("prefixItems/") {
          projection.children[key] = child
        }
        return projection
      }
      let items = nodes.compactMap { $0.children["items"] }
      if let first = items.first {
        let item =
          items.count == 1
          ? first
          : ResolvedSchema(
            value: .object(["allOf": .array(items.map(\.value))]),
            location: first.location, documentURI: first.documentURI,
            children: Dictionary(
              uniqueKeysWithValues: items.enumerated().map { ("allOf/\($0.offset)", $0.element) }),
            modelProvenance: SchemaModelGraph.specialization(
              of: location, path: ["items"], constraints: items)
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
      if node.reference != nil { return }
      guard let object = node.value.object else {
        guard node.value.boolean != nil else {
          throw failure(node.location.pointer, "Expected a schema object or boolean.")
        }
        return
      }
      for (key, value) in object {
        let pointer = node.location.child(key).pointer
        if Self.nonnegativeIntegers.contains(key) {
          _ = try nonnegativeInteger(value, at: pointer)
        } else if Self.numericKeywords.contains(key) {
          let number = try numberLiteral(value, at: pointer)
          if key == "multipleOf", number <= JSONNumberLiteral(0) {
            throw failure(pointer, "'multipleOf' must be greater than zero.")
          }
        } else {
          switch key {
          case "type": _ = try schemaTypes(value, at: pointer)
          case "title", "description", "$comment", "$id", "$schema", "$anchor", "format",
            "contentEncoding", "contentMediaType":
            _ = try string(value, at: pointer)
            if key == "$schema", value.string != "https://json-schema.org/draft/2020-12/schema" {
              throw failure(pointer, "Only the JSON Schema 2020-12 dialect is supported.")
            }
          case "pattern":
            let pattern = try string(value, at: pointer)
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
              throw failure(pointer, "Invalid regular expression: \(error.localizedDescription)")
            }
          case "readOnly", "writeOnly", "deprecated", "uniqueItems":
            _ = try boolean(value, at: pointer)
          case "required":
            guard let keys = value.array else {
              throw failure(pointer, "'required' must be an array of unique property names.")
            }
            let strings = try keys.map { try string($0, at: pointer) }
            guard Set(strings).count == strings.count else {
              throw failure(pointer, "'required' must contain unique property names.")
            }
          case "patternProperties":
            for pattern in value.object.map({ Array($0.keys) }) ?? [] {
              do { _ = try NSRegularExpression(pattern: pattern) } catch {
                throw failure(
                  node.location.child(key).child(pattern).pointer,
                  "Invalid regular expression: \(error.localizedDescription)")
              }
            }
          case "dependentRequired":
            guard let dependencies = value.object else {
              throw failure(pointer, "'dependentRequired' must be an object.")
            }
            for (name, dependency) in dependencies {
              let location = node.location.child(key).child(name).pointer
              guard let values = dependency.array else {
                throw failure(location, "Expected an array of unique property names.")
              }
              let names = try values.map { try string($0, at: location) }
              guard Set(names).count == names.count else {
                throw failure(location, "Expected unique property names.")
              }
            }
          case "$vocabulary":
            guard let vocabularies = value.object else {
              throw failure(pointer, "'$vocabulary' must be an object.")
            }
            for (uri, value) in vocabularies {
              let location = node.location.child(key).child(uri).pointer
              let required = try boolean(value, at: location)
              guard let url = URL(string: uri), url.scheme != nil else {
                throw failure(location, "Vocabulary identifiers must be absolute URIs.")
              }
              if required, !Self.standardVocabularies.contains(uri) {
                throw failure(location, "Unsupported required vocabulary '\(uri)'.")
              }
            }
          case "enum":
            guard value.array != nil else {
              throw failure(pointer, "'enum' must be an array.")
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
    let (type, nullable) = try schemaType(object["type"], at: child(pointer, "type"))
    var requiresValidationDefinition = (object["required"]?.array ?? [])
      .compactMap(\.string).contains { object["properties"]?.object?[$0] == nil }
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
      if object["prefixItems"] != nil {
        expression = SchemaSyntax.call(SchemaSyntax.reference("JSONArray"))
        outputType = .array("JSONValue")
        requiresValidationDefinition = true
        break
      }
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
        requiresValidationDefinition = true
        continue
      }
      if Self.validationOnlyKeywords.contains(key) || !Self.supportedKeywords.contains(key) {
        requiresValidationDefinition = true
        continue
      }
      if Self.nonnegativeIntegers.contains(key) {
        let number = try nonnegativeInteger(keyword, at: location)
        expression = SchemaSyntax.modifier(
          expression, key, [SchemaSyntax.argument(ExprSyntax(literal: number))])
      } else if Self.numericKeywords.contains(key) {
        let number = try numberLiteral(keyword, at: location)
        if key == "multipleOf", number <= JSONNumberLiteral(0) {
          throw failure(location, "'multipleOf' must be greater than zero.")
        }
        expression = SchemaSyntax.modifier(
          expression, key, [SchemaSyntax.argument(try numericArgument(number))])
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
            requiresValidationDefinition = true
            continue
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
    let generated = SchemaFragment(expression: expression, outputType: outputType)
    return requiresValidationDefinition
      ? try applyingValidation(generated, from: node) : generated
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
      guard let values = keyword.array else {
        throw failure(location, "'enum' must be an array.")
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
    let object = SchemaParsingPlan.Object(node)
    var expressions: [ExprSyntax] = []
    var fields: [SchemaOutput.Field] = []
    var modelFields: [SchemaModelGraph.Field] = []
    for property in object.properties {
      let generated = try plan(property.schema)
      let expression = SchemaSyntax.call(
        SchemaSyntax.reference("JSONProperty"),
        [SchemaSyntax.argument(SchemaSyntax.stringLiteral(property.key), label: "key")],
        body: [generated.expression]
      )
      expressions.append(
        property.required ? SchemaSyntax.modifier(expression, "required") : expression)
      let type = property.required ? generated.outputType : .optional(generated.outputType)
      fields.append(
        .init(name: property.label, type: type))
      modelFields.append(
        .init(
          key: property.key, name: property.label, type: type, absent: !property.required))
    }
    var expression =
      fields.isEmpty
      ? SchemaSyntax.call(SchemaSyntax.reference("JSONObject"))
      : SchemaSyntax.call(SchemaSyntax.reference("JSONObject"), body: expressions)
    var outputType: SchemaOutput
    if fields.isEmpty {
      outputType = "Void"
    } else if fields.count == 1 {
      outputType = fields[0].type
    } else {
      outputType = .tuple(fields)
      if options.output == .tuples {
        expression = SchemaSyntax.tupleMap(expression, fields: fields)
      }
    }
    if let additional = object.additional {
      let generated = try plan(additional)
      // Retain the original coverage of declared and pattern properties while
      // parsing extra values. A required-only field is not a declared property.
      if object.preservesCoverage {
        expression = try applyingValidation(
          SchemaFragment(expression: expression, outputType: outputType), from: node
        ).expression
      }
      expression = SchemaSyntax.modifier(
        expression, "additionalProperties",
        closure: ClosureExprSyntax(statements: [
          CodeBlockItemSyntax(leadingTrivia: .newline, item: .expr(generated.expression))
        ]))
      if options.output == .tuples || fields.isEmpty {
        expression = SchemaSyntax.additionalPropertiesMap(
          expression, hasProperties: !fields.isEmpty
        )
      }
      let dictionary = SchemaOutput.dictionary(generated.outputType)
      outputType =
        fields.isEmpty
        ? dictionary
        : .tuple([
          .init(name: "properties", type: outputType),
          .init(name: "additionalProperties", type: dictionary),
        ])
      if !fields.isEmpty {
        let labels = Set(fields.map(\.name))
        var name = "additionalProperties"
        var suffix = 2
        while labels.contains(name) {
          name = "additionalProperties_\(suffix)"
          suffix += 1
        }
        modelFields.append(.init(key: nil, name: name, type: dictionary, absent: false))
      }
    }
    if options.output == .models, !fields.isEmpty || object.additional == nil {
      outputType = models.object(at: node, fields: modelFields)
      expression = SchemaModelSyntax.objectMap(
        expression, output: outputType, fields: modelFields,
        hasAdditional: object.additional != nil && !fields.isEmpty)
    }
    return SchemaFragment(expression: expression, outputType: outputType)
  }

  private func schemaType(_ value: JSONValue?, at pointer: String) throws -> (String?, Bool) {
    guard let types = try schemaTypes(value, at: pointer) else { return (nil, false) }
    return (
      types.first(where: { $0 != "null" }) ?? "null", types.count > 1 && types.contains("null")
    )
  }

  private func schemaTypes(_ value: JSONValue?, at pointer: String) throws -> [String]? {
    guard let value else { return nil }
    if let type = value.string, Self.types.contains(type) { return [type] }
    if let values = value.array {
      let types = try values.enumerated().map { index, value in
        try string(value, at: child(pointer, String(index)))
      }
      guard !types.isEmpty, Set(types).count == types.count,
        types.allSatisfy(Self.types.contains)
      else {
        throw failure(pointer, "'type' must contain unique JSON Schema type names.")
      }
      return types
    }
    throw failure(pointer, "Expected a JSON Schema type name or an array of type names.")
  }

  private func jsonLiteral(_ value: JSONValue, at pointer: String) throws -> ExprSyntax {
    switch value {
    case .string(let value):
      return SchemaSyntax.call(
        SchemaSyntax.member("string"), [SchemaSyntax.argument(SchemaSyntax.stringLiteral(value))])
    case .numberLiteral(let number):
      if let integer = Int(number.rawValue), String(integer) == number.rawValue {
        return SchemaSyntax.call(
          SchemaSyntax.member("integer"), [SchemaSyntax.argument(ExprSyntax(literal: integer))])
      }
      if let double = Double(number.rawValue), double.isFinite,
        try JSONNumberLiteral(double).rawValue == number.rawValue
      {
        return SchemaSyntax.call(
          SchemaSyntax.member("number"), [SchemaSyntax.argument(ExprSyntax(literal: double))])
      }
      return SchemaSyntax.call(
        SchemaSyntax.member("numberLiteral"),
        [SchemaSyntax.argument(exactNumberLiteral(number))])
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

  private func numberLiteral(_ value: JSONValue, at pointer: String) throws -> JSONNumberLiteral {
    guard let number = value.numberLiteral else { throw failure(pointer, "Expected a number.") }
    return number
  }

  private func numericArgument(_ number: JSONNumberLiteral) throws -> ExprSyntax {
    if let double = Double(number.rawValue), double.isFinite,
      try JSONNumberLiteral(double) == number
    {
      return ExprSyntax(literal: double)
    }
    return exactNumberLiteral(number)
  }

  private func exactNumberLiteral(_ number: JSONNumberLiteral) -> ExprSyntax {
    // The generator has already validated this token; reparsing cannot fail.
    ExprSyntax(
      TryExprSyntax(
        questionOrExclamationMark: .exclamationMarkToken(),
        expression: SchemaSyntax.call(
          SchemaSyntax.reference("JSONNumberLiteral"),
          [SchemaSyntax.argument(SchemaSyntax.stringLiteral(number.rawValue))]
        )
      ))
  }

  private func nonnegativeInteger(_ value: JSONValue, at pointer: String) throws -> Int {
    if let integer = value.integer, integer >= 0 { return integer }
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
  private static let typeOrder = [
    "string", "integer", "number", "boolean", "null", "object", "array",
  ]
  private static let types = Set(typeOrder)
  private static let nonnegativeIntegers: Set<String> = [
    "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties",
    "minContains", "maxContains",
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
    "patternProperties": ["object"], "propertyNames": ["object"],
    "dependentRequired": ["object"], "dependentSchemas": ["object"],
    "unevaluatedProperties": ["object"],
    "items": ["array"], "minItems": ["array"], "maxItems": ["array"], "uniqueItems": ["array"],
    "prefixItems": ["array"], "contains": ["array"], "minContains": ["array"],
    "maxContains": ["array"], "unevaluatedItems": ["array"],
    "minLength": ["string"], "maxLength": ["string"], "pattern": ["string"], "format": ["string"],
    "minimum": ["number", "integer"], "maximum": ["number", "integer"],
    "exclusiveMinimum": ["number", "integer"], "exclusiveMaximum": ["number", "integer"],
    "multipleOf": ["number", "integer"],
  ]
  private static let validationOnlyKeywords: Set<String> = [
    "patternProperties", "propertyNames", "dependentRequired", "dependentSchemas",
    "prefixItems", "contains", "minContains", "maxContains", "unevaluatedProperties",
    "unevaluatedItems", "if", "then", "else", "contentEncoding", "contentMediaType",
    "contentSchema", "$vocabulary",
  ]
  private static let standardVocabularies = Set(
    [
      "core", "applicator", "unevaluated", "validation", "meta-data", "format-annotation",
      "format-assertion", "content",
    ].map { "https://json-schema.org/draft/2020-12/vocab/" + $0 })
  private static let supportedKeywords = Set(keywordTypes.keys)
    .union(commonModifierKeywords)
    .union(validationOnlyKeywords)
    .union(["type", "allOf", "anyOf", "oneOf", "not"])
}
