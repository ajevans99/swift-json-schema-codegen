import CustomDump
import JSONSchemaCodegenCore
import Testing

struct SchemaGeneratorTests {
  let generator = SchemaGenerator()

  @Test func labeledOutputPreservesDeclarationOrder() throws {
    let result = try generator.generate("""
      {
        "type": "object",
        "properties": {
          "z": {"type": "integer"},
          "a": {"type": ["string", "null"]}
        },
        "required": ["z"],
        "additionalProperties": false
      }
      """)
    expectNoDifference(result.outputType, "(`z`: Int, `a`: String??)")
    #expect(result.expression.contains(".map { (z: $0.0, a: $0.1) }"))
    #expect(result.expression.contains(".additionalProperties(false)"))
    expectNoDifference(try generator.generate(#"{"type":"object"}"#).outputType, "Void")
  }

  @Test func singletonOutputIsUnwrapped() throws {
    let result = try generator.generate(
      #"{"type":"object","properties":{"value":{"type":"boolean"}},"required":["value"]}"#
    )
    expectNoDifference(result.outputType, "Bool")
    #expect(!result.expression.contains(".map"))
  }

  @Test(arguments: [
    ("true", "JSONValue"),
    ("false", "JSONValue"),
    ("{}", "JSONValue"),
    (#"{"type":"null"}"#, "Void"),
    (#"{"type":"integer"}"#, "Int"),
    (#"{"type":"number"}"#, "Double"),
    (#"{"type":"boolean"}"#, "Bool"),
    (#"{"type":["string"]}"#, "String"),
    (#"{"type":["null","array"],"items":{"type":"string"}}"#, "[String]?"),
  ])
  func primitiveOutputs(source: String, output: String) throws {
    expectNoDifference(try generator.generate(source).outputType, output)
  }

  @Test func nestedArrayOutput() throws {
    let result = try generator.generate("""
      {"type":"array","items":{"type":"object","properties":{
        "name":{"type":"string"},"score":{"type":"number"}
      },"required":["name","score"]}}
      """)
    expectNoDifference(result.outputType, "[(`name`: String, `score`: Double)]")
  }

  @Test(arguments: [
    (##"{"type":"string","$ref":"#/$defs/name"}"##, "/$ref"),
    (#"{"anyOf":[]}"#, "/anyOf"),
    (#"{"type":"object","properties":{"a/b~c":{"type":"string"}}}"#, "/properties/a~1b~0c"),
    (#"{"type":"object","required":["missing"]}"#, "/required"),
    (#"{"type":"object","properties":[]}"#, "/properties"),
    (#"{"type":"object","properties":{"a":{}},"required":["a","a"]}"#, "/required"),
    (#"{"type":"object","additionalProperties":{"type":"string"}}"#, "/additionalProperties"),
    (#"{"type":"string","minimum":2}"#, "/minimum"),
    (#"{"properties":{"x":{"type":"string"}}}"#, "/properties"),
    (#"{"type":"array","minItems":-1}"#, "/minItems"),
    (#"{"type":"string","maxLength":1.5}"#, "/maxLength"),
    (#"{"type":"number","multipleOf":0}"#, "/multipleOf"),
    (#"{"type":"string","pattern":"["}"#, "/pattern"),
    (#"{"type":"string","readOnly":"true"}"#, "/readOnly"),
    (#"{"type":"string","examples":"example"}"#, "/examples"),
    (#"{"type":"string","title":42}"#, "/title"),
    (#"{"type":"array","items":[]}"#, "/items"),
    (#"{"enum":[]}"#, "/enum"),
    (#"{"enum":[1,1.0]}"#, "/enum"),
    (#"{"type":["string","integer"]}"#, "/type"),
    (#"{"type":["string","string"]}"#, "/type"),
    (#"{"type":"object","properties":{"_":{"type":"string"}}}"#, "/properties/_"),
    (#"{"$schema":"http://json-schema.org/draft-07/schema#"}"#, "/$schema"),
  ])
  func rejectsLossyOrMalformedSchemas(source: String, pointer: String) {
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate(source)
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.pointer, pointer)
        throw error
      }
    }
  }

  @Test func invalidJSONDiagnostic() {
    #expect(throws: SchemaGenerationError.self) {
      do {
        _ = try generator.generate("{\n  invalid}")
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.pointer, "")
        #expect(error.description.contains("line 2, column"))
        throw error
      }
    }
  }

  @Test func safeStringEmission() throws {
    let generated = try generator.generate(
      #"{"type":"string","description":"\"\\(fatalError())\n\u0000\u2028"}"#
    )
    #expect(generated.expression.contains(#".description("\"\\(fatalError())\u{a}\u{0}\u{2028}")"#))
  }

  @Test func keywordLabelsAreEscaped() throws {
    let generated = try generator.generate(
      #"{"type":"object","properties":{"default":{"type":"string"},"class":{"type":"integer"}}}"#
    )
    expectNoDifference(generated.outputType, "(`default`: String?, `class`: Int?)")
  }

  @Test func booleanArraySchemaIsPreserved() throws {
    let generated = try generator.generate(#"{"type":"array","items":false}"#)
    expectNoDifference(generated.outputType, "[JSONValue]")
    #expect(generated.expression.contains(#"schema.schemaValue["items"] = .boolean(false)"#))
  }

  @Test func integralBoundsAcceptDecimalSpelling() throws {
    let generated = try generator.generate(#"{"type":"string","minLength":1.0}"#)
    #expect(generated.expression.contains(".minLength(1)"))
  }

  @Test func annotationsAndConstants() throws {
    let generated = try generator.generate("""
      {"type":"string","title":"Name","description":"A name","default":"A",
       "const":"A","examples":["A"],"readOnly":true,"writeOnly":false,"deprecated":false,
       "$comment":"Keep this","$id":"https://example.com/name",
       "$schema":"https://json-schema.org/draft/2020-12/schema"}
      """)
    #expect(generated.expression.contains(#".constant(.string("A"))"#))
    #expect(generated.expression.contains(#".examples(.array([.string("A")]))"#))
    #expect(generated.expression.contains(#".comment("Keep this")"#))
  }

  @Test func nullableConstraintsAreAppliedBeforeTypeErasure() throws {
    let generated = try generator.generate(
      #"{"type":["string","null"],"minLength":2,"enum":["ab",null],"description":"Maybe a name"}"#
    )
    expectNoDifference(generated.outputType, "String?")
    #expect(generated.expression.hasSuffix(".orNull(style: .type)"))
    #expect(generated.expression.contains(".minLength(2)"))
    #expect(generated.expression.contains(#".description("Maybe a name")"#))
    #expect(generated.expression.contains(#"cases: [.string("ab"), .null]"#))
  }
}
