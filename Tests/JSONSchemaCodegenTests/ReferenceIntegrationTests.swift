import CustomDump
import JSONSchemaCodegen
import Testing

@Schema(#"""
  {
    "$schema":"https://json-schema.org/draft/2020-12/schema",
    "$id":"https://styles.example/theme.json",
    "$defs":{
      "hexColor":{"type":"string","pattern":"^#[0-9a-fA-F]{6}$"},
      "typography":{
        "$anchor":"typography",
        "type":"object",
        "properties":{
          "family":{"type":"string","minLength":1},
          "size":{"type":"number","minimum":8,"maximum":96},
          "weight":{"type":"integer","enum":[400,500,600,700]}
        },
        "required":["family","size","weight"],
        "additionalProperties":false
      },
      "button":{
        "type":"object",
        "properties":{
          "background":{"$ref":"#/$defs/hexColor","description":"Button background"},
          "foreground":{"$ref":"#/$defs/hexColor"},
          "label":{"$ref":"#typography"}
        },
        "required":["background","foreground","label"],
        "additionalProperties":false
      }
    },
    "type":"object",
    "properties":{
      "name":{"type":"string","minLength":1},
      "body":{"$ref":"#typography"},
      "buttons":{"type":"array","items":{"$ref":"#/$defs/button"},"minItems":1},
      "accent":{"$ref":"#/$defs/hexColor"}
    },
    "required":["name","body","buttons"],
    "additionalProperties":false
  }
  """#)
private enum DesignThemeSchema {}

struct ReferenceIntegrationTests {
  @Test func realisticThemeDerivesNestedOutputFromReusableDefinitions() throws {
    let value = try DesignThemeSchema.schema.parseAndValidate(instance: #"""
      {
        "name":"Midnight",
        "body":{"family":"Inter","size":16,"weight":400},
        "buttons":[{
          "background":"#3344aa","foreground":"#ffffff",
          "label":{"family":"Inter","size":14,"weight":600}
        }]
      }
      """#)
    expectNoDifference(value.name, "Midnight")
    expectNoDifference(value.body.family, "Inter")
    expectNoDifference(value.body.size, 16)
    expectNoDifference(value.buttons[0].background, "#3344aa")
    expectNoDifference(value.buttons[0].label.weight, 600)
    expectNoDifference(value.accent, nil)
  }

  @Test(arguments: [
    #"""
      {"name":"Midnight","body":{"family":"Inter","size":16,"weight":400},"buttons":[
        {"background":"red","foreground":"#ffffff","label":{"family":"Inter","size":14,"weight":600}}
      ]}
      """#,
    #"""
      {"name":"Midnight","body":{"family":"Inter","size":16},"buttons":[
        {"background":"#3344aa","foreground":"#ffffff","label":{"family":"Inter","size":14,"weight":600}}
      ]}
      """#,
    #"""
      {"name":"Midnight","body":{"family":"Inter","size":160,"weight":400},"buttons":[]}
      """#,
  ])
  func realisticThemeRetainsReferencedConstraints(instance: String) {
    #expect(throws: (any Error).self) {
      try DesignThemeSchema.schema.parseAndValidate(instance: instance)
    }
  }

  @Test func refSiblingsUseIntersectionInsteadOfDictionaryMerge() throws {
    @Schema(#"""
      {
        "$defs":{"label":{"type":"string","minLength":3,"maxLength":12}},
        "$ref":"#/$defs/label","minLength":1,"maxLength":6
      }
      """#)
    enum LabelSchema {}
    expectNoDifference(try LabelSchema.schema.parseAndValidate(instance: #""Hello""#), "Hello")
    for invalid in [#""Hi""#, #""Too long""#] {
      #expect(throws: (any Error).self) {
        try LabelSchema.schema.parseAndValidate(instance: invalid)
      }
    }

    @Schema(#"""
      {
        "$defs":{"object":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
        "$ref":"#/$defs/object","additionalProperties":false
      }
      """#)
    enum ClosedSiblingSchema {}
    // additionalProperties sees only properties declared in its own subschema.
    #expect(throws: (any Error).self) {
      try ClosedSiblingSchema.schema.parseAndValidate(instance: #"{"name":"Blob"}"#)
    }
  }

  @Test func nullableReferenceAndSiblingEnumPreservePresenceSemantics() throws {
    @Schema(#"""
      {
        "$defs":{"accent":{"type":["string","null"],"minLength":3}},
        "type":"object",
        "properties":{
          "name":{"type":"string"},
          "accent":{"$ref":"#/$defs/accent","enum":["blue",null]}
        },
        "required":["name"]
      }
      """#)
    enum NullableThemeSchema {}
    let missing = try NullableThemeSchema.schema.parseAndValidate(instance: #"{"name":"Light"}"#)
    expectNoDifference(missing.accent, Optional<String?>.none)
    let null = try NullableThemeSchema.schema.parseAndValidate(instance: #"{"name":"Light","accent":null}"#)
    expectNoDifference(null.accent, Optional<String?>.some(nil))
    let present = try NullableThemeSchema.schema.parseAndValidate(instance: #"{"name":"Light","accent":"blue"}"#)
    expectNoDifference(present.accent, Optional<String?>.some("blue"))
    #expect(throws: (any Error).self) {
      try NullableThemeSchema.schema.parseAndValidate(instance: #"{"name":"Light","accent":"green"}"#)
    }
  }

  @Test func referencedFalseItemsRemainFalseDuringValidation() throws {
    @Schema(#"""
      {"$defs":{"never":false},"type":"array","items":{"$ref":"#/$defs/never"}}
      """#)
    enum NoItemsSchema {}
    expectNoDifference(try NoItemsSchema.schema.parseAndValidate(instance: "[]"), [JSONValue]())
    #expect(!NoItemsSchema.schema.definition().validate([1]).isValid)
    #expect(throws: (any Error).self) {
      try NoItemsSchema.schema.parseAndValidate(instance: "[1]")
    }
  }
}
