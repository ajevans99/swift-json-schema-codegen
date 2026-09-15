import Foundation
import JSONSchemaCodegenCore
import Testing

@Suite
struct ParserFactoryGenerationTests {
  @Test func complexSharedParsersHaveFreshTypedBoundariesButLegacyOutputStaysInline() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../NamedModels/Fixtures/parser-factories.schema.json")
      .standardizedFileURL
    let document = SchemaDocument(
      source: try String(contentsOf: fixture, encoding: .utf8),
      retrievalURI: URL(string: "https://example.com/complex.json")!)
    let generator = SchemaGenerator(options: .init(output: .models, unknownProperties: .preserve))
    let result = try generator.generateShared(
      document: document, schemaPointers: ["", "/$defs/Level0"], rootNames: ["Root", "Leaf"])
    let factories = result.declarations.filter {
      $0.contains("private static func _JSONSchemaCodegenParser")
    }
    #expect(result.roots[0].expression.utf8.count < 100)
    #expect(!factories.isEmpty)
    #expect(factories.allSatisfy { $0.contains("-> some JSONSchemaComponent<") })
    #expect(factories.filter { $0.contains("JSONSchemaComponent<`Level1`>") }.count > 1)
    #expect(
      result
        == (try generator.generateShared(
          document: document, schemaPointers: ["", "/$defs/Level0"], rootNames: ["Root", "Leaf"])))
    let legacy = try generator.generate(document, referencing: [])
    #expect(!legacy.declarations.contains { $0.contains("func _JSONSchemaCodegenParser") })
    #expect(legacy.expression.utf8.count > 1_000)
  }

  @Test func smallSharedParsersStayInlineAndFactoryNamesAreReserved() throws {
    let document = SchemaDocument(
      source: #"{"type":"object","properties":{"id":{"type":"integer"}}}"#,
      retrievalURI: URL(string: "https://example.com/small.json")!)
    let result = try SchemaGenerator().generateShared(
      document: document, schemaPointers: [""], rootNames: ["Root"])
    #expect(!result.declarations.contains { $0.contains("func _JSONSchemaCodegenParser") })
    #expect(throws: SchemaGenerationError.self) {
      try SchemaGenerator().generateShared(
        document: document, schemaPointers: [""], rootNames: ["_JSONSchemaCodegenParser1"])
    }
  }
}
