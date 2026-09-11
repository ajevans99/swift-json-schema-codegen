import CustomDump
import JSONSchemaCodegenCore
import Testing

struct UnionEmissionTests {
  let generator = SchemaGenerator()

  @Test(arguments: ["anyOf", "oneOf"])
  func annotatedStringUnionUsesPlainBuilders(keyword: String) throws {
    let result = try generator.generate("""
      {
        "description":"A supported web font or a CSS generic family.",
        "\(keyword)":[
          {"type":"string","pattern":"^(Inter|Roboto|Source Sans)$"},
          {"type":"string","pattern":"^(serif|sans-serif|monospace)$"}
        ]
      }
      """)
    let composition = keyword == "anyOf" ? "AnyOf" : "OneOf"
    expectNoDifference(result, GeneratedSchema(
      expression: """
        JSONComposition.\(composition)(into: String.self) {
          JSONString()
          .pattern("^(Inter|Roboto|Source Sans)$")

          JSONString()
          .pattern("^(serif|sans-serif|monospace)$")
        }
        .description("A supported web font or a CSS generic family.")
        """,
      outputType: "String"
    ))
  }

  @Test func mixedUnionOnlyDeclaresItsEnum() throws {
    let result = try generator.generate(#"""
      {"oneOf":[{"type":"string"},{"type":"integer"}],"title":"Token"}
      """#)
    expectNoDifference(result.declarations, [
      """
      public enum Union1: Sendable {
        case option1(String)
        case option2(Int)
      }
      """
    ])
    #expect(result.expression.hasSuffix(#".title("Token")"#))
    #expect(!result.expression.contains("eraseToAnySchemaComponent"))
    #expect(!result.expression.contains("_schema"))
  }

  @Test func nestedUnionDoesNotAddNamespaceHelpers() throws {
    let result = try generator.generate(#"""
      {
        "type":"object",
        "properties":{
          "family":{"anyOf":[{"type":"string","pattern":"^Inter$"},{"type":"string","pattern":"^serif$"}]},
          "size":{"type":"integer","minimum":10}
        },
        "required":["family","size"]
      }
      """#)
    expectNoDifference(result.outputType, "(`family`: String, `size`: Int)")
    expectNoDifference(result.declarations, [])
    #expect(!result.expression.contains("eraseToAnySchemaComponent"))
    #expect(!result.expression.contains(".object("))
  }

  @Test func referenceAnnotationCanUseAnOrdinaryModifier() throws {
    let result = try generator.generate(#"""
      {
        "$defs":{"font":{"anyOf":[{"type":"string","pattern":"^Inter$"},{"type":"string","pattern":"^serif$"}]}},
        "$ref":"#/$defs/font","description":"Font family"
      }
      """#)
    expectNoDifference(result.declarations, [])
    #expect(result.expression.hasSuffix(#".description("Font family")"#))
    #expect(!result.expression.contains("_schema"))
  }

  @Test func nullableReferenceModifiersAreAppliedBeforeNullWrapper() throws {
    let result = try generator.generate(#"""
      {
        "$defs":{"font":{"type":["string","null"]}},
        "$ref":"#/$defs/font","description":"Optional font"
      }
      """#)
    expectNoDifference(result.expression, """
      JSONString()
      .description("Optional font")
      .orNull(style: .type)
      """)
    expectNoDifference(result.declarations, [])
  }

  @Test func constraintsWithNoUnionModifierKeepTheirDefinition() throws {
    let result = try generator.generate(#"""
      {"anyOf":[{"type":"string"},{"type":"integer"}],"type":"string","minLength":3}
      """#)
    #expect(result.declarations.contains { $0.contains("private static func _schemaWithDefinition") })
    #expect(result.expression.contains(#""type": .string("string"), "minLength": .integer(3)"#))
  }

  @Test func conflictingReferenceConstantsStayConjoined() throws {
    let result = try generator.generate(#"""
      {"$defs":{"value":{"type":"string","const":"base"}},"$ref":"#/$defs/value","const":"sibling"}
      """#)
    #expect(result.expression.contains(#""allOf""#))
    #expect(result.expression.contains(#""const": .string("base")"#))
    #expect(result.expression.contains(#""const": .string("sibling")"#))
    #expect(result.declarations.contains { $0.contains("_schemaWithDefinition") })
  }

  @Test func jsonValueUnionsKeepExplicitArraysForCompilerCompatibility() throws {
    let result = try generator.generate(#"{"oneOf":[true,false]}"#)
    expectNoDifference(result.declarations, [])
    #expect(result.expression.hasPrefix("JSONComposition.OneOf(into: JSONValue.self) {\n  ["))
    #expect(result.expression.contains("eraseToAnySchemaComponent()"))
    #expect(!result.expression.contains("_schema"))
  }
}
