import CustomDump
import Foundation
import JSONSchemaCodegenCore
import Testing

struct RootSelectionTests {
  let generator = SchemaGenerator()

  @Test func selectedRootDoesNotEmitRegistryEntryPoints() throws {
    let root = SchemaDocument(
      source: #"{"$ref":"registry.schema.json#/$defs/value"}"#,
      retrievalURI: URL(fileURLWithPath: "/schemas/root.schema.json")
    )
    let registry = SchemaDocument(
      source: #"""
        {"$ref":"missing.schema.json","$defs":{"value":{"type":"string"}}}
        """#,
      retrievalURI: URL(fileURLWithPath: "/schemas/registry.schema.json")
    )

    expectNoDifference(
      try generator.generate(root, referencing: [registry]).outputType, "String"
    )
    #expect(throws: SchemaGenerationError.self) {
      try generator.generate([root, registry])
    }
  }

  @Test func batchStillEmitsEveryInputInOrder() throws {
    let root = SchemaDocument(
      source: #"{"$ref":"registry.schema.json#/$defs/value"}"#,
      retrievalURI: URL(fileURLWithPath: "/schemas/root.schema.json")
    )
    let registry = SchemaDocument(
      source: #"""
        {"type":"integer","$defs":{"value":{"type":"string"}}}
        """#,
      retrievalURI: URL(fileURLWithPath: "/schemas/registry.schema.json")
    )
    let batch = try generator.generate([root, registry])
    expectNoDifference(batch.map(\.outputType), ["String", "Int"])
    expectNoDifference(try generator.generate(root, referencing: [registry]), batch[0])
  }

  @Test func emptyRegistryMatchesInlineGeneration() throws {
    let source = #"{"type":"array","items":{"type":"boolean"}}"#
    let root = SchemaDocument(
      source: source, retrievalURI: URL(fileURLWithPath: "/schemas/root.schema.json")
    )
    expectNoDifference(
      try generator.generate(root, referencing: []), try generator.generate(source)
    )
  }
}
