import CustomDump
import Foundation
import JSONSchemaCodegenCore
import Testing

struct ConfigurationTests {
  @Test func defaultsPreserveTupleRepresentation() {
    expectNoDifference(
      SchemaGenerationOptions(),
      SchemaGenerationOptions(output: .tuples, recursiveObjects: .valueTypes, names: .init())
    )
    expectNoDifference(SchemaNameOverrides().typeNames, [:])
    expectNoDifference(SchemaNameOverrides().caseNames, [:])
  }

  @Test func optionsAreSendableValues() {
    func sendable<T: Sendable>(_ value: T) -> T { value }
    let options = SchemaGenerationOptions(
      output: .models,
      recursiveObjects: .immutableClasses,
      names: .init(
        typeNames: ["#/$defs/payload": "Payload"],
        caseNames: ["#/oneOf/0": "ready"]
      )
    )
    expectNoDifference(sendable(options), options)
  }

  @Test func codablePreservesAllOptionsAndRawValues() throws {
    let options = SchemaGenerationOptions(
      output: .models, recursiveObjects: .immutableClasses,
      names: .init(typeNames: ["#/properties/a~1b": "Payload"], caseNames: ["#/oneOf/0": "ready"])
    )
    let data = try JSONEncoder().encode(options)
    expectNoDifference(try JSONDecoder().decode(SchemaGenerationOptions.self, from: data), options)
    expectNoDifference(SchemaOutputStyle.models.rawValue, "models")
    expectNoDifference(RecursiveObjectStrategy.valueTypes.rawValue, "valueTypes")
    expectNoDifference(RecursiveObjectStrategy.immutableClasses.rawValue, "immutableClasses")
  }

  @Test func configuredCoreKeepsLegacyDefaultAndSelectsNamedModels() throws {
    let source = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
    expectNoDifference(
      try SchemaGenerator().generate(source),
      try SchemaGenerator(options: .init()).generate(source)
    )
    let model = try SchemaGenerator(options: .init(output: .models)).generate(source)
    expectNoDifference(model.outputType, "Value")
    let declarations = model.declarations.joined().replacingOccurrences(of: "`", with: "")
    #expect(declarations.contains("struct Value"))
    #expect(declarations.contains("let name:"))
  }

  @Test func referencedSchemaRetainsOptionsAndLogicalNameAfterRelocation() throws {
    let generator = SchemaGenerator(
      options: .init(
        output: .models,
        names: .init(typeNames: ["#/$defs/Envelope/properties/body": "Payload"])
      )
    )
    let source = #"""
      {"$ref":"#/$defs/Envelope","$defs":{"Envelope":{
        "type":"object","properties":{"body":{
          "type":"object","properties":{"text":{"type":"string"}},"required":["text"]
        }},"required":["body"]
      }}}
      """#
    let document = SchemaDocument(
      source: source, retrievalURI: URL(fileURLWithPath: "/first/Schemas/envelope.schema.json"),
      logicalName: "Schemas/envelope.schema.json"
    )
    let generated = try generator.generate(document, referencing: [])
    expectNoDifference(generated.outputType, "Value")
    #expect(
      generated.declarations.joined()
        .replacingOccurrences(of: "`", with: "").contains("struct Payload")
    )
    let relocated = SchemaDocument(
      source: source,
      retrievalURI: URL(fileURLWithPath: "/second/Schemas/envelope.schema.json"),
      logicalName: document.logicalName
    )
    expectNoDifference(
      try generator.generate(relocated, referencing: []),
      generated
    )
  }
}
