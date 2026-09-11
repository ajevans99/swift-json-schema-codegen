import CustomDump
import Foundation
import JSONSchemaCodegenCore
import Testing

struct OpenAPISchemaGeneratorTests {
  let generator = OpenAPISchemaGenerator()
  let retrievalURI = URL(string: "https://styles.example/openapi.json")!

  @Test func componentsPreserveSourceOrderAndResolveForwardReferences() throws {
    let components = try generate(#"""
      {
        "openapi":"3.1.0",
        "info":{"title":"Styles","version":"1"},
        "paths":{"/themes":{"get":{"responses":{"200":{
          "description":"A theme",
          "content":{"application/json":{"schema":{"$ref":"#/components/schemas/Theme"}}}
        }}}}},
        "components":{"schemas":{
          "Theme":{"type":"object","properties":{
            "name":{"type":"string"},
            "body":{"$ref":"#/components/schemas/Typography"}
          },"required":["name","body"]},
          "Typography":{"type":"object","properties":{
            "family":{"type":"string"},"size":{"type":"integer","minimum":10}
          },"required":["family","size"]},
          "Anything":true,
          "Nothing":false
        }}
      }
      """#)
    expectNoDifference(components.map(\.name), ["Theme", "Typography", "Anything", "Nothing"])
    expectNoDifference(
      components[0].schema.outputType,
      "(`name`: String, `body`: (`family`: String, `size`: Int))"
    )
    expectNoDifference(components[1].schema.outputType, "(`family`: String, `size`: Int)")
    expectNoDifference(components[2].schema.outputType, "JSONValue")
    #expect(components[0].schema.expression.contains(".minimum(10.0)"))
  }

  @Test func escapedComponentPointersAreNotRebased() throws {
    let components = try generate(#"""
      {"openapi":"3.1.1","components":{"schemas":{
        "Alias":{"$ref":"#/components/schemas/a~1b~0c"},
        "a/b~c":{"type":"integer"}
      }}}
      """#)
    expectNoDifference(components.map(\.name), ["Alias", "a/b~c"])
    expectNoDifference(components[0].schema, components[1].schema)
    expectNoDifference(components[0].schema.outputType, "Int")
  }

  @Test(arguments: [
    #"{"openapi":"3.1.0"}"#,
    #"{"openapi":"3.1.0","components":{}}"#,
    #"{"openapi":"3.1.0","components":{"schemas":{}}}"#,
  ])
  func missingOrEmptyComponents(source: String) throws {
    expectNoDifference(try generate(source), [])
  }

  @Test(arguments: [
    "https://spec.openapis.org/oas/3.1/dialect/base",
    "https://json-schema.org/draft/2020-12/schema",
  ])
  func recognizedDialects(dialect: String) throws {
    let components = try generate("""
      {"openapi":"3.1.0","jsonSchemaDialect":"\(dialect)","components":{"schemas":{
        "Name":{"$schema":"\(dialect)","type":"string"}
      }}}
      """)
    expectNoDifference(components[0].schema.outputType, "String")
  }

  @Test func dialectNormalizationPreservesNamesIDsReferencesAndAnnotationValues() throws {
    let components = try generate(#"""
      {"openapi":"3.1.0","components":{"schemas":{
        "Alias":{"$ref":"types.json#/$defs/name"},
        "Types":{
          "$id":"types.json",
          "$schema":"https://spec.openapis.org/oas/3.1/dialect/base",
          "$defs":{"name":{
            "$schema":"https://spec.openapis.org/oas/3.1/dialect/base",
            "type":"string","minLength":2
          }},
          "type":"object",
          "properties":{"name":{"$ref":"#/$defs/name"},"enabled":{"type":"boolean"}},
          "required":["name"],
          "examples":[{"$schema":"https://spec.openapis.org/oas/3.1/dialect/base"}]
        }
      }}}
      """#)
    expectNoDifference(components.map(\.name), ["Alias", "Types"])
    expectNoDifference(components[0].schema.outputType, "String")
    expectNoDifference(components[1].schema.outputType, "(`name`: String, `enabled`: Bool?)")
    #expect(components[0].schema.expression.contains(".minLength(2)"))
    #expect(components[1].schema.expression.contains("https://spec.openapis.org/oas/3.1/dialect/base"))
  }

  @Test func componentIDsKeepTheirOwnResourceScope() throws {
    let components = try generate(#"""
      {"openapi":"3.1.0","components":{"schemas":{
        "Alias":{"$ref":"types/typography.json#font"},
        "Typography":{
          "$id":"types/typography.json",
          "$defs":{"font":{"$anchor":"font","type":"string","minLength":1}},
          "type":"object",
          "properties":{"family":{"$ref":"#font"},"size":{"type":"integer"}},
          "required":["family","size"]
        }
      }}}
      """#)
    expectNoDifference(components[0].schema.outputType, "String")
    expectNoDifference(components[1].schema.outputType, "(`family`: String, `size`: Int)")
  }

  @Test func nonSchemaOpenAPIMetadataIsNotIndexed() throws {
    let components = try generate(#"""
      {
        "openapi":"3.1.0",
        "$id":"https://wrong.example/ignored",
        "info":{"$id":"duplicate","$schema":"not-a-schema-dialect"},
        "components":{
          "examples":{"Example":{"value":{"$id":"duplicate"}}},
          "schemas":{"Name":{
            "type":"string",
            "examples":[{"$id":"duplicate","$schema":"not-a-schema-dialect"}]
          }}
        }
      }
      """#)
    expectNoDifference(components[0].schema.outputType, "String")
  }

  @Test(arguments: [
    ("[]", "", "document object"),
    (#"{"openapi":"3.1.0","#, "", "Invalid JSON"),
    (#"{}"#, "/openapi", "Only OpenAPI 3.1.x"),
    (#"{"openapi":"3.0.3"}"#, "/openapi", "nullable"),
    (#"{"openapi":"3.2.0"}"#, "/openapi", "Only OpenAPI 3.1.x"),
    (#"{"openapi":"3.1"}"#, "/openapi", "Only OpenAPI 3.1.x"),
    (#"{"openapi":"3.1.0\n"}"#, "/openapi", "Only OpenAPI 3.1.x"),
    (#"{"openapi":3.1}"#, "/openapi", "Only OpenAPI 3.1.x"),
    (#"{"openapi":"3.1.0","jsonSchemaDialect":"https://example.com/custom"}"#,
     "/jsonSchemaDialect", "dialects"),
    (#"{"openapi":"3.1.0","jsonSchemaDialect":null}"#, "/jsonSchemaDialect", "dialects"),
    (#"{"openapi":"3.1.0","components":[]}"#, "/components", "object"),
    (#"{"openapi":"3.1.0","components":{"schemas":null}}"#, "/components/schemas", "object"),
    (#"{"openapi":"3.1.0","components":{"schemas":[]}}"#, "/components/schemas", "object"),
    (#"{"openapi":"3.1.0","components":{"schemas":{"a/b~c":42}}}"#,
     "/components/schemas/a~1b~0c", "schema object or boolean"),
    (#"{"openapi":"3.1.0","components":{"schemas":{"Bad":[]}}}"#,
     "/components/schemas/Bad", "schema object or boolean"),
    (#"{"openapi":"3.1.0","components":{"schemas":{"Bad":null}}}"#,
     "/components/schemas/Bad", "schema object or boolean"),
    (#"{"openapi":"3.1.0","components":{"schemas":{"Bad":"string"}}}"#,
     "/components/schemas/Bad", "schema object or boolean"),
  ])
  func malformedDocumentsHaveLocatedErrors(source: String, pointer: String, message: String) throws {
    try expectFailure(source, pointer: pointer, message: message)
  }

  @Test(arguments: [
    (#"{"type":"string","nullable":true}"#, "/nullable", "nullable"),
    (#"{"type":"object","discriminator":{"propertyName":"kind"}}"#,
     "/discriminator", "discriminator"),
    (#"{"$schema":"https://json-schema.org/draft-07/schema","type":"string"}"#,
     "/$schema", "dialect"),
    (#"{"$ref":"https://unregistered.example/types.json"}"#, "/$ref", "No files or URLs"),
    (##"{"$ref":"#/info"}"##, "/$ref", "schema"),
    (##"{"$ref":"#/components/schemas/Bad"}"##, "/$ref", "Recursive reference"),
  ])
  func unsupportedSchemasDoNotSilentlyWeakenValidation(
    schema: String, pointer: String, message: String
  ) throws {
    try expectFailure(
      """
      {"openapi":"3.1.0","info":{"type":"string"},"components":{"schemas":{"Bad":\(schema)}}}
      """,
      pointer: "/components/schemas/Bad" + pointer, message: message
    )
  }

  @Test func fixtureGeneratesCompositionAndSupportingDeclarations() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Examples/OpenAPIExample/Fixtures/style-api.openapi.json")
    let components = try generator.generateComponents(
      in: SchemaDocument(
        source: String(contentsOf: fixtureURL, encoding: .utf8),
        retrievalURI: retrievalURI
      )
    )
    let theme = try #require(components.first { $0.name == "Theme" }?.schema)
    #expect(theme.outputType.contains("`id`: String"))
    #expect(theme.outputType.contains("`name`: String"))
    #expect(theme.outputType.contains("`palette`:"))
    #expect(theme.outputType.contains("`body`:"))
    let response = try #require(components.first { $0.name == "ThemeResponse" }?.schema)
    expectNoDifference(response.outputType, "Union1")
    #expect(response.declarations.contains { $0.contains("public enum Union1") })
    #expect(response.declarations.contains { $0.contains("case option2(") })
    let font = try #require(components.first { $0.name == "FontFamily" }?.schema)
    expectNoDifference(font.outputType, "String")
    expectNoDifference(font.declarations, [])
    #expect(!font.expression.contains("eraseToAnySchemaComponent"))
    #expect(font.expression.hasSuffix(
      #".description("A supported web font or a CSS generic family.")"#
    ))

    let typography = try #require(components.first { $0.name == "Typography" }?.schema)
    expectNoDifference(typography.declarations, [])
    #expect(!typography.expression.contains("_schema"))
    #expect(!typography.expression.contains(".object("))
    #expect(!typography.expression.contains("eraseToAnySchemaComponent"))
    #expect(theme.declarations.contains { $0.contains("_schemaWithDefinition") })
  }

  private func generate(_ source: String) throws -> [GeneratedOpenAPISchema] {
    try generator.generateComponents(in: SchemaDocument(source: source, retrievalURI: retrievalURI))
  }

  private func expectFailure(_ source: String, pointer: String, message: String) throws {
    do {
      _ = try generate(source)
      Issue.record("Expected generation to fail at \(pointer)")
    } catch let error as SchemaGenerationError {
      expectNoDifference(error.pointer, pointer)
      expectNoDifference(error.documentURI, retrievalURI)
      #expect(error.message.contains(message))
    }
  }
}
