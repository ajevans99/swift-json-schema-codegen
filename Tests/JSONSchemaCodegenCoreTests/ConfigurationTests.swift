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

  @Test func openAPIForwardsOptionsAndRetainsLogicalNameThroughNormalization() throws {
    let generator = OpenAPISchemaGenerator(
      options: .init(
        output: .models,
        names: .init(typeNames: ["#/components/schemas/Envelope/properties/body": "Payload"])
      )
    )
    let source = #"""
      {"openapi":"3.1.0","components":{"schemas":{"Envelope":{
        "$schema":"https://spec.openapis.org/oas/3.1/dialect/base",
        "type":"object","properties":{"body":{
          "type":"object","properties":{"text":{"type":"string"}},"required":["text"]
        }},"required":["body"]
      }}}}
      """#
    let document = SchemaDocument(
      source: source, retrievalURI: URL(string: "https://example.com/openapi.json")!,
      logicalName: "API/openapi.json"
    )
    let components = try generator.generateComponents(in: document)
    expectNoDifference(components.map(\.name), ["Envelope"])
    expectNoDifference(components[0].schema.outputType, "Value")
    #expect(
      components[0].schema.declarations.joined()
        .replacingOccurrences(of: "`", with: "").contains("struct Payload")
    )
    let normalized = SchemaDocument(
      source: source.replacingOccurrences(
        of: "https://spec.openapis.org/oas/3.1/dialect/base",
        with: "https://json-schema.org/draft/2020-12/schema"
      ),
      retrievalURI: document.retrievalURI, logicalName: document.logicalName
    )
    expectNoDifference(
      try generator.generateComponents(in: normalized),
      components
    )
  }
}
