import CustomDump
import JSONSchemaCodegenCore
import Testing

struct CompositionGenerationTests {
  let generator = SchemaGenerator()

  @Test func allOfObjectFieldsAreCombinedInDeclarationOrder() throws {
    let result = try generator.generate(#"""
      {"allOf":[
        {"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]},
        {"properties":{"name":{"type":"string"},"active":{"type":"boolean"}},"required":["name"]}
      ]}
      """#)
    expectNoDifference(result.outputType, "(`id`: Int, `name`: String, `active`: Bool?)")
    #expect(!result.declarations.contains(where: { $0.hasPrefix("public enum") }))
    #expect(result.expression.contains(#""allOf""#))
  }

  @Test func overlappingPropertiesIntersectAndRequiredNamesCombine() throws {
    let result = try generator.generate(#"""
      {"allOf":[
        {"type":"object","properties":{"name":{"type":"string","minLength":3}},"required":["name"]},
        {"type":"object","properties":{"name":{"maxLength":8},"age":{"type":"integer"}}},
        {"required":["age"]}
      ]}
      """#)
    expectNoDifference(result.outputType, "(`name`: String, `age`: Int)")
    #expect(result.expression.contains(#""minLength": .integer(3)"#))
    #expect(result.expression.contains(#""maxLength": .integer(8)"#))
  }

  @Test func nestedAllOfArraysAndNullableTypes() throws {
    let result = try generator.generate(#"""
      {"allOf":[
        {"type":["array","null"],"items":{"type":["number","null"]}},
        {"type":"array","items":{"type":"integer","minimum":1}}
      ]}
      """#)
    expectNoDifference(result.outputType, "[Int]")
  }

  @Test(arguments: ["anyOf", "oneOf"])
  func sameTypeUnionKeepsOutput(keyword: String) throws {
    let result = try generator.generate("""
      {"\(keyword)":[{"type":"string","minLength":5},{"type":"string","maxLength":3}]}
      """)
    expectNoDifference(result.outputType, "String")
    #expect(!result.declarations.contains(where: { $0.hasPrefix("public enum") }))
    #expect(result.expression.contains("JSONComposition."))
  }

  @Test(arguments: ["anyOf", "oneOf"])
  func mixedUnionDeclaresEnum(keyword: String) throws {
    let result = try generator.generate("""
      {"\(keyword)":[{"type":"string"},{"type":"number"},{"type":"null"}]}
      """)
    expectNoDifference(result.outputType, "Union1")
    expectNoDifference(result.declarations.filter { $0.hasPrefix("public enum") }, [
      """
      public enum Union1: Sendable {
        case option1(String)
        case option2(Double)
        case option3(Void)
      }
      """
    ])
    #expect(result.expression.contains("""
      .map { @Sendable (value: String) -> Union1 in
          Union1.option1(value)
        }
      """))
  }

  @Test func nestedUnionDeclarationsAreReturnedAndReused() throws {
    let result = try generator.generate(#"""
      {
        "type":"object",
        "properties":{
          "a":{"oneOf":[{"type":"string"},{"type":"boolean"}]},
          "b":{"anyOf":[{"type":"string"},{"type":"boolean"}]}
        },
        "required":["a","b"]
      }
      """#)
    expectNoDifference(result.outputType, "(`a`: Union1, `b`: Union1)")
    expectNoDifference(result.declarations.filter { $0.hasPrefix("public enum") }.count, 1)
  }

  @Test func unionObjectOrderDoesNotSwapPayloadFields() throws {
    let result = try generator.generate(#"""
      {"oneOf":[
        {"type":"object","properties":{"a":{"type":"string"},"b":{"type":"string"}}},
        {"type":"object","properties":{"b":{"type":"string"},"a":{"type":"string"}}}
      ]}
      """#)
    expectNoDifference(result.outputType, "Union1")
    #expect(result.declarations[0].contains("option1((`a`: String?, `b`: String?))"))
    #expect(result.declarations[0].contains("option2((`b`: String?, `a`: String?))"))
  }

  @Test func referencesIntoCompositionBranchesResolve() throws {
    let result = try generator.generate(#"""
      {
        "$defs":{"union":{"anyOf":[{"type":"string"},{"type":"integer"}]}},
        "$ref":"#/$defs/union/anyOf/1"
      }
      """#)
    expectNoDifference(result.outputType, "Int")
  }

  @Test func refStructuralSiblingAddsFields() throws {
    let result = try generator.generate(#"""
      {
        "$defs":{"base":{"type":"object","properties":{"id":{"type":"string"}}}},
        "$ref":"#/$defs/base",
        "properties":{"name":{"type":"string"}},"required":["name","id"]
      }
      """#)
    expectNoDifference(result.outputType, "(`id`: String, `name`: String)")
  }

  @Test(arguments: [
    (#"{"allOf":[]}"#, "/allOf"),
    (#"{"anyOf":true}"#, "/anyOf"),
    (#"{"oneOf":[42]}"#, "/oneOf/0"),
    (#"{"allOf":[{"type":"string"},{"unknown":true}]}"#, "/allOf/1/unknown"),
    (#"{"oneOf":[{"type":"string","minLength":-1},{"type":"integer"}]}"#, "/oneOf/0/minLength"),
    (#"{"allOf":[{"type":"object"},{"required":["x","x"]}]}"#, "/allOf/1/required"),
    (#"{"allOf":[{"type":"object"},{"properties":{"bad/key":{"type":"string"}}}]}"#, "/allOf/1/properties/bad~1key"),
    (#"{"not":{"anyOf":[]}}"#, "/not/anyOf"),
    (##"{"$defs":{"never":false},"$ref":"#/$defs/never","unknown":true}"##, "/unknown"),
  ])
  func malformedCompositionDiagnostics(source: String, pointer: String) {
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
