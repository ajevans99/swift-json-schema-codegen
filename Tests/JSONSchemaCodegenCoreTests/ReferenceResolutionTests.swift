import CustomDump
import Foundation
import JSONSchemaCodegenCore
import Testing

struct ReferenceResolutionTests {
  let generator = SchemaGenerator()

  @Test func localDefinitionsPreserveRequirednessAndLabels() throws {
    let generated = try generator.generate(#"""
      {
        "$defs": {
          "color": {"type":"string","pattern":"^#[0-9a-fA-F]{6}$"},
          "spacing": {"type":"integer","minimum":0,"maximum":128}
        },
        "type":"object",
        "properties":{
          "background":{"$ref":"#/$defs/color"},
          "gap":{"$ref":"#/$defs/spacing"}
        },
        "required":["background"]
      }
      """#)
    expectNoDifference(generated.outputType, "(`background`: String, `gap`: Int?)")
    #expect(generated.expression.contains(#".pattern("^#[0-9a-fA-F]{6}$")"#))
    #expect(generated.expression.contains(".maximum(128.0)"))
    #expect(!generated.expression.contains("$ref"))
    #expect(!generated.expression.contains("$defs"))
  }

  @Test func chainedReferencesAndBooleanItems() throws {
    let generated = try generator.generate(#"""
      {
        "$defs":{"never":false,"alias":{"$ref":"#/$defs/never"}},
        "type":"array","items":{"$ref":"#/$defs/alias"}
      }
      """#)
    expectNoDifference(generated.outputType, "[JSONValue]")
    #expect(generated.expression.contains(#"schema.schemaValue["items"] = .boolean(false)"#))
  }

  @Test(arguments: [
    ("a~1b~0c", "a/b~c"),
    ("%E2%9C%93", "\u{2713}"),
    ("01", "01"),
    ("", ""),
    ("tilde~01", "tilde~1"),
  ])
  func pointerTokensAreDecodedExactlyOnce(fragment: String, key: String) throws {
    let source = """
      {"$defs":{"\(key)":{"type":"integer"}},"$ref":"#/$defs/\(fragment)"}
      """
    expectNoDifference(try generator.generate(source).outputType, "Int")
  }

  @Test func relativeReferencesShareOneBatchRegistry() throws {
    let theme = document(#"""
      {"type":"object","properties":{
        "primary":{"$ref":"../shared/tokens.schema.json#/$defs/color"},
        "spacing":{"$ref":"../shared/tokens.schema.json#/$defs/spacing"}
      },"required":["primary","spacing"]}
      """#, at: "themes/theme.schema.json")
    let tokens = document(#"""
      {"$defs":{
        "color":{"type":"string","minLength":7},
        "spacing":{"type":"number","minimum":0}
      }}
      """#, at: "shared/tokens.schema.json")
    let forward = try generator.generate([theme, tokens])
    let reverse = try generator.generate([tokens, theme])
    expectNoDifference(forward[0].outputType, "(`primary`: String, `spacing`: Double)")
    expectNoDifference(forward[0], reverse[1])
    expectNoDifference(forward[1], reverse[0])
    #expect(forward[0].expression.contains(".minLength(7)"))
  }

  @Test func retrievalURIAndCanonicalIDAreAliases() throws {
    let types = document(#"""
      {"$id":"https://styles.example/schema/types.json","$defs":{"color":{"type":"string"}}}
      """#, at: "types.schema.json")
    let byPath = document(#"""
      {"$ref":"types.schema.json#/$defs/color"}
      """#, at: "path.schema.json")
    let byID = document(#"""
      {"$ref":"https://styles.example/schema/types.json#/$defs/color"}
      """#, at: "canonical.schema.json")
    let results = try generator.generate([types, byPath, byID])
    expectNoDifference(results[1], results[2])
    expectNoDifference(results[1].outputType, "String")
  }

  @Test func nestedIDResetsScopeAndSupportsForwardReferences() throws {
    let source = #"""
      {
        "$id":"https://styles.example/schemas/root.json",
        "$defs":{
          "palette":{
            "$id":"nested/palette.json",
            "$defs":{
              "color":{"type":"string","minLength":7},
              "selected":{"$ref":"#/$defs/color"}
            },
            "$ref":"#/$defs/selected"
          }
        },
        "$ref":"nested/palette.json"
      }
      """#
    let generated = try generator.generate(source)
    expectNoDifference(generated.outputType, "String")
    #expect(generated.expression.contains(".minLength(7)"))
    #expect(!generated.expression.contains(#".id("nested/palette.json")"#))
    #expect(generated.expression.contains(#".id("https://styles.example/schemas/root.json")"#))
    expectNoDifference(generated.declarations, [])
  }

  @Test func pointersEnteringNestedResourcesUseTheirBaseURI() throws {
    let root = document(#"""
      {
        "$id":"https://styles.example/root.json",
        "$defs":{"palette":{
          "$id":"nested/palette.json",
          "type":"object",
          "properties":{"color":{"$ref":"color.json"}}
        }},
        "$ref":"#/$defs/palette/properties/color"
      }
      """#, at: "root.schema.json")
    let color = document(#"""
      {"$id":"https://styles.example/nested/color.json","type":"string"}
      """#, at: "color.schema.json")
    expectNoDifference(try generator.generate([root, color])[0].outputType, "String")
  }

  @Test func staticAnchorsAreScopedToResources() throws {
    let source = #"""
      {
        "$id":"https://styles.example/root.json",
        "$defs":{
          "outer":{"$anchor":"color","type":"boolean"},
          "nested":{
            "$id":"palette.json",
            "$defs":{"inner":{"$anchor":"color","type":"string"}},
            "$ref":"#color"
          }
        },
        "$ref":"palette.json"
      }
      """#
    expectNoDifference(try generator.generate(source).outputType, "String")
  }

  @Test func anchorsWorkThroughRetrievalAliasesAndURNs() throws {
    let types = document(#"""
      {"$id":"urn:example:types","$defs":{"color":{"$anchor":"color","type":"string"}}}
      """#, at: "types.schema.json")
    let byFile = document(#"{"$ref":"types.schema.json#color"}"#, at: "theme.schema.json")
    let byURN = document(#"{"$ref":"urn:example:types#color"}"#, at: "settings.schema.json")
    let results = try generator.generate([types, byFile, byURN])
    expectNoDifference(results[1], results[2])
    expectNoDifference(results[1].outputType, "String")

    let inline = #"""
      {"$id":"urn:example:inline","$defs":{"value":{"type":"number"}},"$ref":"#/$defs/value"}
      """#
    expectNoDifference(try generator.generate(inline).outputType, "Double")
  }

  @Test func siblingConstraintsAreIntersectedNotOverwritten() throws {
    let generated = try generator.generate(#"""
      {
        "$defs":{"label":{"type":"string","minLength":3,"maxLength":12}},
        "$ref":"#/$defs/label",
        "minLength":1,"maxLength":6,"description":"A compact label"
      }
      """#)
    expectNoDifference(generated.outputType, "String")
    for modifier in [
      #""minLength": .integer(3)"#, #""minLength": .integer(1)"#,
      #""maxLength": .integer(12)"#, #""maxLength": .integer(6)"#,
    ] {
      #expect(generated.expression.contains(modifier))
    }
    #expect(generated.expression.contains(#""allOf""#))
    #expect(generated.declarations.joined().contains("eraseToAnySchemaComponent()"))
  }

  @Test func unusedRecursiveDefinitionsDoNotPreventGeneration() throws {
    let source = #"""
      {"$defs":{"unused":{"$ref":"#/$defs/unused"}},"type":"string"}
      """#
    expectNoDifference(try generator.generate(source).outputType, "String")
  }

  @Test func annotationsDoNotRegisterSchemaResources() throws {
    let source = #"""
      {"type":"string","default":{"$id":"https://example.com/fake"},"examples":[{"$anchor":"fake"}]}
      """#
    #expect(try generator.generate(source).expression.contains(".`default`("))
  }

  @Test(arguments: [
    (#"{"$ref":false}"#, "/$ref", "Expected a string"),
    (#"{"$defs":[]}"#, "/$defs", "must be an object"),
    (#"{"$defs":{"value":42}}"#, "/$defs/value", "schema object or boolean"),
    (##"{"$ref":"#/$defs/missing"}"##, "/$ref", "Unresolved JSON Pointer"),
    (##"{"$defs":{"a":{}},"$ref":"#/$defs/a~2"}"##, "/$ref", "Invalid JSON Pointer escape"),
    (##"{"$ref":"#bad"}"##, "/$ref", "Unresolved anchor"),
    (##"{"$ref":"#"}"##, "/$ref", "Recursive reference"),
    (##"{"$defs":{"a":{"$ref":"#/$defs/b"},"b":{"$ref":"#/$defs/a"}},"$ref":"#/$defs/a"}"##, "/$defs/b/$ref", "Recursive reference"),
    (#"{"$ref":"https://example.com/not-supplied.json"}"#, "/$ref", "No files or URLs"),
    (#"{"$ref":"bad%2"}"#, "/$ref", "Invalid URI"),
    (#"{"$ref":"https://example.com/with space"}"#, "/$ref", "Invalid URI"),
    (#"{"$id":"https://example.com/root#fragment"}"#, "/$id", "nonempty fragment"),
    (#"{"$anchor":"1bad"}"#, "/$anchor", "valid static anchor"),
    (##"{"$defs":{"legacy":{"$id":"legacy.json","$schema":"http://json-schema.org/draft-07/schema#","$defs":{"value":{}}}},"$ref":"legacy.json#/$defs/value"}"##, "/$defs/legacy/$schema", "2020-12 dialect"),
    (##"{"default":{"type":"string"},"$ref":"#/default"}"##, "/$ref", "schema-bearing location"),
    (##"{"$defs":{"first":{"$anchor":"same"},"second":{"$anchor":"same"}}}"##, "/$defs/second/$anchor", "Duplicate '$anchor'"),
  ])
  func invalidReferencesHavePreciseDiagnostics(source: String, pointer: String, message: String) {
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate(source)
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.pointer, pointer)
        expectNoDifference(error.documentURI, nil)
        #expect(error.message.contains(message))
        throw error
      }
    }
  }

  @Test func referencedDefinitionErrorsKeepOriginalSourceLocation() {
    let consumer = document(#"{"$ref":"types.schema.json#/$defs/color"}"#, at: "theme.schema.json")
    let types = document(#"""
      {"$defs":{"color":{"type":"string","minLength":-1}}}
      """#, at: "types.schema.json")
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate([consumer, types])
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.documentURI, types.retrievalURI)
        expectNoDifference(error.pointer, "/$defs/color/minLength")
        #expect(error.description.contains("types.schema.json: #/$defs/color/minLength"))
        throw error
      }
    }
  }

  @Test func duplicateCanonicalIDsAndRetrievalURIsAreRejected() {
    let first = document(#"{"$id":"https://EXAMPLE.com:443/shared.json"}"#, at: "a.schema.json")
    let second = document(#"{"$id":"https://example.com/shared.json"}"#, at: "b.schema.json")
    #expect(throws: SchemaGenerationError.self) {
      try generator.generate([first, second])
    }
    #expect(throws: SchemaGenerationError.self) {
      try generator.generate([first, first])
    }
  }

  @Test func canonicalIDsCannotStealAnotherInputsRetrievalURI() {
    let first = document(#"{"$id":"b.schema.json"}"#, at: "a.schema.json")
    let second = document("{}", at: "b.schema.json")
    #expect(throws: SchemaGenerationError.self) {
      try generator.generate([first, second])
    }
  }

  @Test func unreservedURIEscapesAndDotSegmentsAreNormalized() throws {
    let types = document(#"""
      {"$id":"https://example.com/a/../%74ypes.json","type":"string"}
      """#, at: "types.schema.json")
    let consumer = document(#"{"$ref":"https://EXAMPLE.com:443/types.json"}"#, at: "consumer.schema.json")
    expectNoDifference(try generator.generate([types, consumer])[1].outputType, "String")
  }

  @Test func reservedURIEscapesDoNotBecomePathSeparators() throws {
    let first = document(#"{"$id":"https://example.com/a%2fb","type":"string"}"#, at: "a.schema.json")
    let second = document(#"{"$id":"https://example.com/a/b","type":"boolean"}"#, at: "b.schema.json")
    let consumer = document(#"{"$ref":"https://example.com/a%2Fb"}"#, at: "consumer.schema.json")
    expectNoDifference(try generator.generate([first, second, consumer])[2].outputType, "String")
  }

  @Test func crossDocumentCyclesReportTheClosingReference() {
    let first = document(#"{"$ref":"b.schema.json"}"#, at: "a.schema.json")
    let second = document(#"{"$ref":"a.schema.json"}"#, at: "b.schema.json")
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate([first, second])
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.documentURI, second.retrievalURI)
        expectNoDifference(error.pointer, "/$ref")
        #expect(error.message.contains("a.schema.json"))
        #expect(error.message.contains("b.schema.json"))
        throw error
      }
    }
  }

  @Test func missingReferencesPointToTheirOwnDocument() {
    let consumer = document(#"{"$ref":"types.schema.json#/$defs/color"}"#, at: "theme.schema.json")
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate([consumer])
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.documentURI, consumer.retrievalURI)
        expectNoDifference(error.pointer, "/$ref")
        throw error
      }
    }
  }

  @Test func repeatedReferenceGraphsHaveABoundedExpansion() {
    var definitions = [#""value0":{"type":"string"}"#]
    for depth in 1...16 {
      definitions.append("""
        "value\(depth)":{"type":"object","properties":{
          "left":{"$ref":"#/$defs/value\(depth - 1)"},
          "right":{"$ref":"#/$defs/value\(depth - 1)"}
        }}
        """)
    }
    let source = """
      {"$defs":{\(definitions.joined(separator: ","))},"$ref":"#/$defs/value16"}
      """
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate(source)
      } catch let error as SchemaGenerationError {
        #expect(error.message.contains("10000 emitted nodes"))
        throw error
      }
    }
  }

  @Test func emptyBatchIsEmptyAndRetrievalFragmentsAreRejected() throws {
    expectNoDifference(try generator.generate([SchemaDocument]()), [])
    let uri = try #require(URL(string: "https://example.com/schema.json#fragment"))
    #expect(throws: SchemaGenerationError.self) {
      try generator.generate([SchemaDocument(source: "{}", retrievalURI: uri)])
    }
  }

  private func document(_ source: String, at path: String) -> SchemaDocument {
    SchemaDocument(source: source, retrievalURI: URL(fileURLWithPath: "/schemas/" + path))
  }
}
