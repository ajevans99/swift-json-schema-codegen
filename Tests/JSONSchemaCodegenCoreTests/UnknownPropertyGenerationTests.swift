import Foundation
import JSONSchemaCodegenCore
import Testing

@Suite
struct UnknownPropertyGenerationTests {
  @Test func optionsKeepExistingCodableDefaults() throws {
    let legacy = Data(
      #"{"output":"models","recursiveObjects":"valueTypes","names":{"typeNames":{},"caseNames":{}}}"#
        .utf8)
    let decoded = try JSONDecoder().decode(SchemaGenerationOptions.self, from: legacy)
    #expect(decoded.unknownProperties == .discard)
    let encoded = try JSONEncoder().encode(decoded)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("unknownProperties"))
    let preserving = SchemaGenerationOptions(output: .models, unknownProperties: .preserve)
    #expect(
      try JSONDecoder().decode(
        SchemaGenerationOptions.self, from: JSONEncoder().encode(preserving)) == preserving)
  }

  @Test func preservationIsExplicitAndOnlyUsesNamedOutputs() throws {
    let source = #"{"type":"object","properties":{"id":{"type":"string"}}}"#
    let tuple = SchemaGenerator(options: .init(unknownProperties: .preserve))
    #expect(throws: SchemaGenerationError.self) { try tuple.generate(source) }
    let named = try SchemaGenerator(options: .init(output: .models, unknownProperties: .preserve))
      .generate(source)
    #expect(
      named.declarations.contains { $0.contains("`unmodeledProperties`: [String: JSONValue]") })
    let shared = try tuple.generateShared(
      document: .init(
        source: source, retrievalURI: URL(string: "https://example.com/unknown.json")!),
      schemaPointers: [""], rootNames: ["Root"])
    #expect(
      shared.declarations.contains { $0.contains("`unmodeledProperties`: [String: JSONValue]") })
    let existing = try SchemaGenerator(options: .init(output: .models)).generate(source)
    #expect(!existing.declarations.contains { $0.contains("unmodeledProperties") })
  }

  @Test func unmodeledStorageAvoidsDeclaredAndTypedExtraNames() throws {
    let source = #"""
      {"type":"object","properties":{
        "unmodeledProperties":{"type":"string"},
        "unmodeledProperties_2":{"type":"string"},
        "additionalProperties":{"type":"string"}
      },"additionalProperties":{"type":"integer"}}
      """#
    let result = try SchemaGenerator(options: .init(unknownProperties: .preserve)).generateShared(
      document: .init(
        source: source, retrievalURI: URL(string: "https://example.com/unknown.json")!),
      schemaPointers: [""], rootNames: ["Root"])
    let text = result.declarations.joined(separator: "\n")
    #expect(text.contains("let `unmodeledProperties_3`: [String: JSONValue]"))
    #expect(text.contains("`unmodeledProperties_3`: [String: JSONValue] = [:]"))
    #expect(text.contains("let `additionalProperties_2`: [String: Int]"))
    #expect(text.contains("object[key] == nil"))
  }

  @Test func pureTypedDictionariesKeepTheirExistingValueRepresentation() throws {
    let source = #"{"type":"object","additionalProperties":{"type":"string"}}"#
    let options = SchemaGenerationOptions(output: .models, unknownProperties: .preserve)
    let result = try SchemaGenerator(options: options).generate(source)
    #expect(result.declarations.contains { $0.contains("typealias Value = [String: String]") })
    #expect(!result.declarations.contains { $0.contains("unmodeledProperties") })
  }
}
