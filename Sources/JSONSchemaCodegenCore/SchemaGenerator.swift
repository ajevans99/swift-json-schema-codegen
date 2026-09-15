import Foundation
import JSONSchemaCodegenConfiguration

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

/// Multiple entry points whose models and helpers belong in one enclosing Swift namespace.
public struct GeneratedSharedSchemas: Equatable, Sendable {
  public let declarations: [String]
  public let roots: [GeneratedSharedSchemaRoot]
}

/// A publicly nameable output, parser expression, and throwing model-to-JSON function reference.
public struct GeneratedSharedSchemaRoot: Equatable, Sendable {
  public let name: String
  public let outputType: String
  public let expression: String
  /// A static function reference, `Self.encode<RootName>`, of type `(RootName) throws -> JSONValue`.
  public let encodingExpression: String
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

  /// Generates named outputs and JSON mappings for roots in a shared namespace.
  ///
  /// This is an explicit opt-in to named models, regardless of `options.output`.
  /// Root pointers address schemas within a raw JSON container; referenced JSON
  /// Pointers are registered as schemas on demand. No OpenAPI normalization or I/O
  /// is performed. Root names must be unique, nonreserved ASCII Swift identifiers.
  /// Place all declarations and parser expressions in the same enclosing type.
  public func generateShared(
    document: SchemaDocument, schemaPointers: [String], rootNames: [String]
  ) throws -> GeneratedSharedSchemas {
    guard schemaPointers.count == rootNames.count else {
      throw SchemaGenerationError(
        pointer: "", message: "Shared schema pointers and root names must have equal counts.",
        documentURI: document.retrievalURI)
    }
    guard !schemaPointers.isEmpty else {
      return GeneratedSharedSchemas(declarations: [], roots: [])
    }
    var sharedOptions = options
    sharedOptions.output = .models
    let graph = try SchemaReferenceGraph(
      documents: [document], schemaPointers: schemaPointers,
      allowsUnindexedReferences: true)
    var emitter = SchemaEmitter(options: sharedOptions)
    return try emitter.generateShared(graph.schemas(at: schemaPointers), rootNames: rootNames)
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
