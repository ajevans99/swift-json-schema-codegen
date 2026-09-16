import Foundation
import JSONSchemaCodegenCore

func generateParserFactoryModels(output: URL) throws {
  let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures").standardizedFileURL
  let source = try String(
    contentsOf: fixtures.appendingPathComponent("parser-factories.schema.json"), encoding: .utf8)
  let document = SchemaDocument(
    source: source, retrievalURI: URL(string: "https://example.com/complex.json")!)
  let generator = SchemaGenerator(options: .init(output: .models, unknownProperties: .preserve))
  let shared = try generator.generateShared(
    document: document, schemaPointers: ["", "/$defs/Level0"], rootNames: ["Root", "Leaf"])
  guard shared.roots[0].expression.utf8.count < 100,
    shared.declarations.contains(where: {
      $0.contains("private static func _JSONSchemaCodegenParser")
    })
  else {
    throw NSError(
      domain: "ParserFactoryFixture", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Complex shared parser was not split at typed boundaries."
      ])
  }
  try writeShared(shared, namespace: "FactorySchemas", output: output)
  let legacy = try generator.generate(document, referencing: [])
  let legacySource = """
    import JSONSchema
    import JSONSchemaBuilder
    public enum LegacyFactorySchemas {
    \(legacy.declarations.joined(separator: "\n"))
    public static var schema: some JSONSchemaComponent<\(legacy.outputType)> {
    \(legacy.expression)
    }
    }
    """
  try legacySource.write(
    to: output.appendingPathComponent("LegacyFactorySchemas.swift"), atomically: true,
    encoding: .utf8)
}
