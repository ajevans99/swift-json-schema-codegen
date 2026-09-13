import Foundation
import OrderedJSON

/// A named OpenAPI component and its generated JSONSchemaBuilder source.
public struct GeneratedOpenAPISchema: Equatable, Sendable {
  public let name: String
  public let schema: GeneratedSchema

  public init(name: String, schema: GeneratedSchema) {
    self.name = name
    self.schema = schema
  }
}

/// Generates the supported JSON Schema subset of OpenAPI 3.1 JSON components.
///
/// This is a components adapter, not an OpenAPI document validator or HTTP client
/// generator. Only `components.schemas` and their schema-bearing descendants are
/// indexed. References retain their full document pointers and `$id` scopes.
/// Generation performs no file or network I/O. YAML, OpenAPI 3.0, and custom
/// dialects are not supported. OpenAPI-only keywords such as `discriminator`
/// remain annotations rather than changing validation or generated types.
public struct OpenAPISchemaGenerator: Sendable {
  public let options: SchemaGenerationOptions

  /// Uses the same representation, recursion policy, and names as `SchemaGenerator`.
  public init(options: SchemaGenerationOptions = .init()) {
    self.options = options
  }

  /// Returns components in source order, retaining their original names.
  ///
  /// The OpenAPI 3.1 base dialect and JSON Schema 2020-12 are recognized, but only
  /// the keywords supported by `SchemaGenerator` can be lowered. An explicit
  /// OpenAPI base `$schema` is lowered to the JSON Schema 2020-12 dialect without
  /// changing references, identifiers, or annotation values. Place each
  /// result's supporting declarations and expression in its own Swift namespace.
  /// Missing `components` or `schemas` produces an empty result.
  public func generateComponents(in document: SchemaDocument) throws -> [GeneratedOpenAPISchema] {
    func failure(_ pointer: String, _ message: String) -> SchemaGenerationError {
      SchemaGenerationError(
        pointer: pointer, message: message, documentURI: document.retrievalURI
      )
    }

    let value: JSONValue
    do {
      value = try JSONValue.parse(document.source)
    } catch let error as JSONParseError {
      throw failure(
        "", "Invalid JSON at line \(error.line), column \(error.column): \(error.message)"
      )
    }
    guard var object = value.object else {
      throw failure("", "Expected an OpenAPI document object.")
    }
    guard let version = object["openapi"]?.string,
      version.range(of: #"\A3\.1\.[0-9]+\z"#, options: .regularExpression) != nil
    else {
      throw failure(
        "/openapi",
        "Only OpenAPI 3.1.x JSON documents are supported; OpenAPI 3.0 nullable semantics are not supported."
      )
    }
    if let dialect = object["jsonSchemaDialect"] {
      guard let uri = dialect.string,
        uri == "https://spec.openapis.org/oas/3.1/dialect/base"
          || uri == "https://json-schema.org/draft/2020-12/schema"
      else {
        throw failure(
          "/jsonSchemaDialect",
          "Only the OpenAPI 3.1 base and JSON Schema 2020-12 dialects are supported."
        )
      }
    }
    guard let componentsValue = object["components"] else { return [] }
    guard var components = componentsValue.object else {
      throw failure("/components", "Expected an object.")
    }
    guard let schemasValue = components["schemas"] else { return [] }
    guard var schemas = schemasValue.object else {
      throw failure("/components/schemas", "Expected an object of named schemas.")
    }
    let names = Array(schemas.keys)
    let pointers = names.map {
      "/components/schemas/"
        + $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
    for (name, pointer) in zip(names, pointers) {
      guard let schema = schemas[name], schema.object != nil || schema.boolean != nil else {
        throw failure(pointer, "Expected a schema object or boolean.")
      }
    }
    var changed = false
    for name in names {
      if let schema = schemas[name] {
        schemas[name] = normalizingDialect(in: schema, changed: &changed)
      }
    }
    let schemaDocument: SchemaDocument
    if changed {
      components["schemas"] = .object(schemas)
      object["components"] = .object(components)
      schemaDocument = SchemaDocument(
        source: try JSONValue.object(object).serialized(),
        retrievalURI: document.retrievalURI,
        logicalName: document.logicalName
      )
    } else {
      schemaDocument = document
    }
    let generated = try SchemaGenerator(options: options).generate(
      schemaDocument, schemaPointers: pointers
    )
    return zip(names, generated).map { GeneratedOpenAPISchema(name: $0.0, schema: $0.1) }
  }

  private func normalizingDialect(in value: JSONValue, changed: inout Bool) -> JSONValue {
    guard var object = value.object else { return value }
    if object["$schema"]?.string == "https://spec.openapis.org/oas/3.1/dialect/base" {
      object["$schema"] = .string("https://json-schema.org/draft/2020-12/schema")
      changed = true
    }
    for keyword in SchemaKeywords.maps {
      if var children = object[keyword]?.object {
        for name in children.keys {
          if let child = children[name] {
            children[name] = normalizingDialect(in: child, changed: &changed)
          }
        }
        object[keyword] = .object(children)
      }
    }
    for keyword in SchemaKeywords.singles {
      if let child = object[keyword] {
        object[keyword] = normalizingDialect(in: child, changed: &changed)
      }
    }
    for keyword in SchemaKeywords.arrays {
      if let children = object[keyword]?.array {
        object[keyword] = .array(
          children.map { normalizingDialect(in: $0, changed: &changed) }
        )
      }
    }
    return .object(object)
  }
}
