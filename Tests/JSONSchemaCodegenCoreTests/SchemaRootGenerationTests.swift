import CustomDump
import Foundation
import Testing

@testable import JSONSchemaCodegenCore

struct SchemaRootGenerationTests {
  let generator = SchemaGenerator()
  let retrievalURI = URL(string: "https://styles.example/schemas.json")!

  @Test func selectedRootsPreserveOrderAndResolveForwardReferences() throws {
    let source = #"""
      {"$defs":{
        "Theme":{"type":"object","properties":{
          "name":{"type":"string"},"body":{"$ref":"#/$defs/Typography"}
        },"required":["name","body"]},
        "Typography":{"type":"object","properties":{
          "family":{"type":"string"},"size":{"type":"integer","minimum":10}
        },"required":["family","size"]},
        "Anything":true,"Nothing":false
      }}
      """#
    let pointers = ["/$defs/Theme", "/$defs/Typography", "/$defs/Anything", "/$defs/Nothing"]
    let results = try generate(source, pointers: pointers)
    expectNoDifference(results.count, 4)
    expectNoDifference(
      results[0].outputType, "(`name`: String, `body`: (`family`: String, `size`: Int))")
    expectNoDifference(results[1].outputType, "(`family`: String, `size`: Int)")
    expectNoDifference(results[2].outputType, "JSONValue")
    #expect(results[0].expression.contains(".minimum(10.0)"))
    expectNoDifference(
      try generate(source, pointers: Array(pointers.reversed())),
      Array(results.reversed()))
  }

  @Test func selectedRootsPreserveEscapedPointers() throws {
    let results = try generate(
      #"""
      {"$defs":{"Alias":{"$ref":"#/$defs/a~1b~0c"},"a/b~c":{"type":"integer"}}}
      """#,
      pointers: ["/$defs/Alias", "/$defs/a~1b~0c"])
    expectNoDifference(results[0], results[1])
    expectNoDifference(results[0].outputType, "Int")
  }

  @Test func selectedRootsRetainResourceAndAnchorScope() throws {
    let results = try generate(
      #"""
      {"$defs":{
        "Alias":{"$ref":"types/typography.json#font"},
        "Typography":{
          "$id":"types/typography.json",
          "$defs":{"font":{"$anchor":"font","type":"string","minLength":1}},
          "type":"object",
          "properties":{"family":{"$ref":"#font"},"size":{"type":"integer"}},
          "required":["family","size"]
        }
      }}
      """#,
      pointers: ["/$defs/Alias", "/$defs/Typography"])
    expectNoDifference(results[0].outputType, "String")
    expectNoDifference(results[1].outputType, "(`family`: String, `size`: Int)")
    #expect(results[0].expression.contains(".minLength(1)"))
  }

  @Test func selectedRootsDoNotIndexUnselectedData() throws {
    let results = try generate(
      #"""
      {
        "metadata":{"$id":"duplicate","$schema":"not-a-schema-dialect"},
        "examples":[{"$id":"duplicate"}],
        "$defs":{"Name":{"type":"string","examples":[{"$id":"duplicate"}]}}
      }
      """#,
      pointers: ["/$defs/Name"])
    expectNoDifference(results[0].outputType, "String")
  }

  @Test(arguments: [
    (
      #"{"$schema":"https://json-schema.org/draft-07/schema","type":"string"}"#, "/$schema",
      "dialect"
    ),
    (#"{"$ref":"https://unregistered.example/types.json"}"#, "/$ref", "No files or URLs"),
    (##"{"$ref":"#/metadata"}"##, "/$ref", "schema"),
    (##"{"$ref":"#/$defs/Bad"}"##, "/$ref", "Recursive reference"),
  ])
  func selectedRootFailuresRetainSourceLocations(
    schema: String, pointer: String, message: String
  ) {
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generate(
          #"{"metadata":{"type":"string"},"$defs":{"Bad":\#(schema)}}"#,
          pointers: ["/$defs/Bad"])
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.pointer, "/$defs/Bad" + pointer)
        expectNoDifference(error.documentURI, retrievalURI)
        #expect(error.message.contains(message))
        throw error
      }
    }
  }

  private func generate(_ source: String, pointers: [String]) throws -> [GeneratedSchema] {
    try generator.generate(
      SchemaDocument(source: source, retrievalURI: retrievalURI), schemaPointers: pointers)
  }
}
