import Foundation
import JSONSchemaCodegenCore

func generateUnionReferenceModels(output: URL) throws {
  let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures/union-reference-annotations.json").standardizedFileURL
  let document = SchemaDocument(
    source: try String(contentsOf: fixture, encoding: .utf8),
    retrievalURI: URL(string: "https://example.com/union.json")!)
  let entries = [
    ("first", "First"), ("second", "Second"), ("plain", "Plain"),
    ("nullableFirst", "NullableFirst"), ("nullableSecond", "NullableSecond"),
    ("specializedFirst", "SpecializedFirst"), ("specializedSecond", "SpecializedSecond"),
    ("strict", "Strict"), ("ambiguous", "AmbiguousRoot"),
  ]
  let shared = try SchemaGenerator(options: .init(unknownProperties: .preserve)).generateShared(
    document: document, schemaPointers: entries.map { "/properties/" + $0.0 },
    rootNames: entries.map(\.1))
  try writeShared(shared, namespace: "UnionReferenceSchemas", output: output)
  let legacy = try SchemaGenerator(options: .init(output: .models)).generate(
    document, referencing: [])
  let legacySource = """
    import JSONSchema
    import JSONSchemaBuilder
    public enum LegacyUnionReferenceSchemas {
    \(legacy.declarations.joined(separator: "\n"))
    public static var schema: some JSONSchemaComponent<\(legacy.outputType)> {
    \(legacy.expression)
    }
    }
    """
  try legacySource.write(
    to: output.appendingPathComponent("LegacyUnionReferenceSchemas.swift"), atomically: true,
    encoding: .utf8)
}
