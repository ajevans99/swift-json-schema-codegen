import CustomDump
import JSONSchemaCodegenCore
import Testing

struct KeywordGenerationTests {
  let generator = SchemaGenerator()

  @Test func multipleTypesGenerateTypedUnion() throws {
    let generated = try generator.generate(
      #"{"type":["string","integer","boolean"],"minLength":2,"minimum":0}"#
    )
    expectNoDifference(generated.outputType, "Union1")
    let declaration = try #require(generated.declarations.first { $0.hasPrefix("public enum") })
    #expect(declaration.contains("case option1(String)"))
    #expect(declaration.contains("case option2(Int)"))
    #expect(declaration.contains("case option3(Bool)"))
    #expect(
      generated.expression.contains(
        #""type": .array([.string("string"), .string("integer"), .string("boolean")])"#))
  }

  @Test(arguments: [
    (#"{"type":"object","additionalProperties":{"type":"integer"}}"#, "[String: Int]"),
    (
      #"{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],"additionalProperties":{"type":"string"}}"#,
      "(`properties`: Int, `additionalProperties`: [String: String])"
    ),
    (#"{"type":"object","required":["undeclared"]}"#, "JSONValue"),
    (
      #"{"type":"object","properties":{"declared":{"type":"string"}},"required":["undeclared"]}"#,
      "(`declared`: String?, `undeclared`: JSONValue)"
    ),
    (
      #"{"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],"items":{"type":"boolean"}}"#,
      "[JSONValue]"
    ),
    (#"{"properties":{"name":{"type":"string"}},"required":["name"]}"#, "JSONValue"),
    (#"{"type":"string","minimum":4,"items":false}"#, "String"),
  ])
  func projectedOutput(source: String, expected: String) throws {
    expectNoDifference(try generator.generate(source).outputType, expected)
  }

  @Test func annotationsArePreservedWithoutInterpretingTheirContents() throws {
    let generated = try generator.generate(
      #"""
      {"type":"string",
       "x-extension":{"$ref":"missing.json","$id":42,"items":[]},
       "contentEncoding":"base64","contentMediaType":"application/json",
       "contentSchema":{"type":"object"}}
      """#)
    #expect(generated.expression.contains(#""x-extension""#))
    #expect(generated.expression.contains(#""$ref": .string("missing.json")"#))
    #expect(generated.expression.contains(#""contentSchema""#))
    expectNoDifference(generated.outputType, "String")
  }

  @Test func standardAndOptionalVocabulariesAreRecognized() throws {
    let generated = try generator.generate(
      #"""
      {"$vocabulary":{
        "https://json-schema.org/draft/2020-12/vocab/core":true,
        "https://json-schema.org/draft/2020-12/vocab/applicator":true,
        "https://json-schema.org/draft/2020-12/vocab/validation":true,
        "https://example.com/optional":false
      }}
      """#)
    #expect(generated.expression.contains(#""$vocabulary""#))
    expectNoDifference(generated.outputType, "JSONValue")
  }

  @Test(arguments: [
    (#"{"enum":[]}"#, "cases: []"),
    (#"{"enum":[1,1.0]}"#, "cases: [.integer(1), .number(1.0)]"),
  ])
  func enumNeedNotBeNonemptyOrUnique(source: String, emitted: String) throws {
    #expect(try generator.generate(source).expression.contains(emitted))
  }

  @Test(arguments: [
    (#"{"dependentRequired":[]}"#, "/dependentRequired"),
    (#"{"dependentRequired":{"a":true}}"#, "/dependentRequired/a"),
    (#"{"dependentRequired":{"a":["x","x"]}}"#, "/dependentRequired/a"),
    (#"{"patternProperties":{"[":true}}"#, "/patternProperties/["),
    (#"{"propertyNames":42}"#, "/propertyNames"),
    (#"{"dependentSchemas":{"a":42}}"#, "/dependentSchemas/a"),
    (#"{"prefixItems":[]}"#, "/prefixItems"),
    (#"{"contains":[]}"#, "/contains"),
    (#"{"minContains":-1}"#, "/minContains"),
    (#"{"maxContains":1.5}"#, "/maxContains"),
    (#"{"if":42}"#, "/if"),
    (#"{"unevaluatedItems":42}"#, "/unevaluatedItems"),
    (#"{"unevaluatedProperties":[]}"#, "/unevaluatedProperties"),
    (#"{"contentEncoding":42}"#, "/contentEncoding"),
    (#"{"contentMediaType":false}"#, "/contentMediaType"),
    (#"{"contentSchema":null}"#, "/contentSchema"),
    (#"{"$vocabulary":[]}"#, "/$vocabulary"),
    (
      #"{"$vocabulary":{"https://example.com/unknown":true}}"#,
      "/$vocabulary/https:~1~1example.com~1unknown"
    ),
    (#"{"$vocabulary":{"relative":false}}"#, "/$vocabulary/relative"),
    (
      #"{"$vocabulary":{"https://example.com/unknown":0}}"#,
      "/$vocabulary/https:~1~1example.com~1unknown"
    ),
    (#"{"enum":true}"#, "/enum"),
  ])
  func malformedKeywordsAreRejected(source: String, pointer: String) {
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate(source)
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.pointer, pointer)
        throw error
      }
    }
  }
}
