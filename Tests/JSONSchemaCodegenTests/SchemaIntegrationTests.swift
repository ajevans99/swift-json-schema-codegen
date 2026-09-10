import CustomDump
import JSONSchemaCodegen
import Testing

@Schema(#"{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name"]}"#)
public enum PublicSchemaFixture {}

@Suite
struct SchemaIntegrationTests {
  @Test func publicNamespaceExposesTypedSchema() throws {
    let value = try PublicSchemaFixture.schema.parseAndValidate(instance: #"{"name":"Blob"}"#)
    expectNoDifference(value.name, "Blob")
    expectNoDifference(value.age, nil)
  }

  @Test func infersLabeledTupleWithoutContextualType() throws {
    @Schema("""
      {
        "type": "object",
        "properties": {
          "primaryColor": {"type": "string", "pattern": "^#[0-9a-fA-F]{6}$"},
          "iconUrl": {"type": "string"}
        },
        "required": ["primaryColor"]
      }
      """)
    enum ThemeSchema {}
    let component = ThemeSchema.schema

    let theme = try component.parseAndValidate(instance: ##"{"primaryColor":"#aabbcc"}"##)
    let primaryColor: String = theme.primaryColor
    let iconUrl: String? = theme.iconUrl
    expectNoDifference(primaryColor, "#aabbcc")
    expectNoDifference(iconUrl, nil)

    let complete = try component.parseAndValidate(
      instance: ##"{"primaryColor":"#123456","iconUrl":"https://example.com/icon.png"}"##
    )
    expectNoDifference(complete.iconUrl, "https://example.com/icon.png")
    #expect(throws: (any Error).self) {
      try component.parseAndValidate(instance: #"{"primaryColor":"red"}"#)
    }
    #expect(throws: (any Error).self) {
      try component.parseAndValidate(instance: "{}")
    }
  }

  @Test func nestedObjectsAndHomogeneousArrays() throws {
    @Schema("""
      {
        "type": "object",
        "properties": {
          "owner": {
            "type": "object",
            "properties": {"name": {"type": "string"}, "active": {"type": "boolean"}},
            "required": ["name", "active"]
          },
          "items": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {"id": {"type": "integer"}, "tags": {"type": "array", "items": {"type": "string"}}},
              "required": ["id", "tags"]
            }
          }
        },
        "required": ["owner", "items"]
      }
      """)
    enum NestedSchema {}
    let component = NestedSchema.schema
    let output = try component.parseAndValidate(
      instance: #"{"owner":{"name":"Blob","active":true},"items":[{"id":1,"tags":["swift","json"]}]}"#
    )
    let owner = output.owner
    let items = output.items
    expectNoDifference(owner.name, "Blob")
    expectNoDifference(owner.active, true)
    expectNoDifference(items[0].id, 1)
    expectNoDifference(items[0].tags, ["swift", "json"])
    #expect(throws: (any Error).self) {
      try component.parseAndValidate(
        instance: #"{"owner":{"name":"Blob","active":true},"items":[{"id":1,"tags":[42]}]}"#
      )
    }
  }

  @Test func requirednessIsIndependentOfNullability() throws {
    @Schema("""
      {
        "type": "object",
        "properties": {
          "required": {"type": "string"},
          "optional": {"type": "string"},
          "requiredNullable": {"type": ["string", "null"]},
          "optionalNullable": {"type": ["string", "null"]}
        },
        "required": ["required", "requiredNullable"]
      }
      """)
    enum NullableSchema {}
    let component = NullableSchema.schema
    let absent = try component.parseAndValidate(
      instance: #"{"required":"present","requiredNullable":null}"#
    )
    let required: String = absent.required
    let optional: String? = absent.optional
    let requiredNullable: String? = absent.requiredNullable
    let optionalNullable: String?? = absent.optionalNullable
    expectNoDifference(required, "present")
    expectNoDifference(optional, nil)
    expectNoDifference(requiredNullable, nil)
    expectNoDifference(optionalNullable, Optional<String?>.none)

    let null = try component.parseAndValidate(
      instance: #"{"required":"present","requiredNullable":null,"optionalNullable":null}"#
    )
    expectNoDifference(null.optionalNullable, Optional<String?>.some(nil))

    let value = try component.parseAndValidate(
      instance: #"{"required":"present","optional":"value","requiredNullable":"value","optionalNullable":"value"}"#
    )
    expectNoDifference(value.optional, "value")
    expectNoDifference(value.requiredNullable, "value")
    expectNoDifference(value.optionalNullable, Optional<String?>.some("value"))

    #expect(throws: (any Error).self) {
      try component.parseAndValidate(instance: #"{"required":"present"}"#)
    }
    #expect(throws: (any Error).self) {
      try component.parseAndValidate(
        instance: #"{"required":"present","optional":null,"requiredNullable":null}"#
      )
    }
  }

  @Test func singletonAndEmptyObjects() throws {
    @Schema(
      #"{"type":"object","properties":{"value":{"type":"integer"}},"required":["value"]}"#
    )
    enum SingletonSchema {}
    let singleton = SingletonSchema.schema
    let value: Int = try singleton.parseAndValidate(instance: #"{"value":42}"#)
    expectNoDifference(value, 42)

    @Schema(
      #"{"type":"object","properties":{"value":{"type":"integer"}}}"#
    )
    enum OptionalSingletonSchema {}
    let optionalSingleton = OptionalSingletonSchema.schema
    let missing: Int? = try optionalSingleton.parseAndValidate(instance: "{}")
    expectNoDifference(missing, nil)

    @Schema(#"{"type":"object","additionalProperties":false}"#)
    enum EmptySchema {}
    let empty = EmptySchema.schema
    let _: Void = try empty.parseAndValidate(instance: "{}")
    #expect(throws: (any Error).self) {
      try empty.parseAndValidate(instance: #"{"unexpected":1}"#)
    }
  }

  @Test func escapedKeysAndKeywordLabels() throws {
    @Schema(
      #"{"type":"object","properties":{"\u006eame":{"type":"string"},"class":{"type":"integer"}},"required":["name","class"]}"#
    )
    enum EscapedSchema {}
    let component = EscapedSchema.schema
    let output = try component.parseAndValidate(instance: #"{"name":"Blob","class":6}"#)
    let name: String = output.name
    let keyword: Int = output.class
    expectNoDifference(name, "Blob")
    expectNoDifference(keyword, 6)
  }

  @Test func swiftLiteralEscapeSemantics() throws {
    @Schema("{\"type\":\"\u{73}tring\",\"const\":\"hello\\nworld\"}")
    enum EscapedSchema {}
    let escaped = EscapedSchema.schema
    expectNoDifference(try escaped.parseAndValidate(instance: #""hello\nworld""#), "hello\nworld")

    @Schema("""
      {"type": \
      "string", "const": "ok"}
      """)
    enum ContinuedSchema {}
    let continued = ContinuedSchema.schema
    expectNoDifference(try continued.parseAndValidate(instance: #""ok""#), "ok")

    @Schema(#"{"type":"string","pattern":"^\\d+$"}"#)
    enum RawSchema {}
    let raw = RawSchema.schema
    expectNoDifference(try raw.parseAndValidate(instance: #""123""#), "123")
    #expect(throws: (any Error).self) {
      try raw.parseAndValidate(instance: #""abc""#)
    }
  }

  @Test func stringConstraints() throws {
    @Schema(
      #"{"type":"string","minLength":2,"maxLength":4,"pattern":"^[a-z]+$"}"#
    )
    enum StringSchema {}
    let component = StringSchema.schema
    expectNoDifference(try component.parseAndValidate(instance: #""abc""#), "abc")
    for invalid in [#""a""#, #""abcde""#, #""ABC""#] {
      #expect(throws: (any Error).self) {
        try component.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func numberConstraints() throws {
    @Schema(
      #"{"type":"number","minimum":0,"maximum":10,"exclusiveMinimum":1,"exclusiveMaximum":9,"multipleOf":0.5}"#
    )
    enum NumberSchema {}
    let component = NumberSchema.schema
    let value: Double = try component.parseAndValidate(instance: "4.5")
    expectNoDifference(value, 4.5)
    for invalid in ["-1", "11", "1", "9", "4.2"] {
      #expect(throws: (any Error).self) {
        try component.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func arrayConstraints() throws {
    @Schema(
      #"{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":3,"uniqueItems":true}"#
    )
    enum ArraySchema {}
    let component = ArraySchema.schema
    let value: [Int] = try component.parseAndValidate(instance: "[1,2]")
    expectNoDifference(value, [1, 2])
    for invalid in ["[1]", "[1,2,3,4]", "[1,1]", #"[1,"2"]"#] {
      #expect(throws: (any Error).self) {
        try component.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func objectConstraints() throws {
    @Schema("""
      {
        "type": "object",
        "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}, "c": {"type": "integer"}},
        "minProperties": 1,
        "maxProperties": 2,
        "additionalProperties": false
      }
      """)
    enum ObjectSchema {}
    let component = ObjectSchema.schema
    let value = try component.parseAndValidate(instance: #"{"a":1}"#)
    expectNoDifference(value.a, 1)
    for invalid in ["{}", #"{"a":1,"b":2,"c":3}"#, #"{"unknown":1}"#] {
      #expect(throws: (any Error).self) {
        try component.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func booleanSchemas() throws {
    @Schema("true")
    enum TrueSchema {}
    let acceptsAnything = TrueSchema.schema
    expectNoDifference(
      try acceptsAnything.parseAndValidate(instance: #"{"value":[1,null]}"#),
      JSONValue.object(["value": .array([.integer(1), .null])])
    )
    @Schema("false")
    enum FalseSchema {}
    let acceptsNothing = FalseSchema.schema
    for invalid in ["null", "1", "{}", "[]"] {
      #expect(throws: (any Error).self) {
        try acceptsNothing.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func booleanArrayItemSchemas() throws {
    @Schema(#"{"type":"array","items":true}"#)
    enum AnyItemsSchema {}
    let anyItems = AnyItemsSchema.schema
    expectNoDifference(
      try anyItems.parseAndValidate(instance: #"[1,"two",null]"#),
      [JSONValue.integer(1), .string("two"), .null]
    )
    @Schema(#"{"type":"array","items":false}"#)
    enum NoItemsSchema {}
    let noItems = NoItemsSchema.schema
    expectNoDifference(try noItems.parseAndValidate(instance: "[]"), [JSONValue]())
    #expect(throws: (any Error).self) {
      try noItems.parseAndValidate(instance: "[1]")
    }
  }

  @Test func emptySchemaAndNullPrimitive() throws {
    @Schema("{}")
    enum AnyValueSchema {}
    expectNoDifference(
      try AnyValueSchema.schema.parseAndValidate(instance: "[true,1]"),
      JSONValue.array([.boolean(true), .integer(1)])
    )

    @Schema(#"{"type":"null"}"#)
    enum NullSchema {}
    let _: Void = try NullSchema.schema.parseAndValidate(instance: "null")
    #expect(throws: (any Error).self) {
      try NullSchema.schema.parseAndValidate(instance: "false")
    }
  }

  @Test func nullableEnumDoesNotWeakenConstraints() throws {
    @Schema(
      #"{"type":["string","null"],"enum":["ready",null],"minLength":3,"title":"Status","default":"ready"}"#
    )
    enum StatusSchema {}
    let component = StatusSchema.schema
    let null: String? = try component.parseAndValidate(instance: "null")
    expectNoDifference(null, nil)
    expectNoDifference(try component.parseAndValidate(instance: #""ready""#), "ready")
    expectNoDifference(component.schemaValue["title"], .string("Status"))
    expectNoDifference(component.schemaValue["default"], .string("ready"))
    #expect(throws: (any Error).self) {
      try component.parseAndValidate(instance: #""unknown""#)
    }

    @Schema(#"{"type":["string","null"],"const":"ready"}"#)
    enum ConstantSchema {}
    #expect(throws: (any Error).self) {
      try ConstantSchema.schema.parseAndValidate(instance: "null")
    }
  }

  @Test func nullableContainersRetainObjectAndArrayConstraints() throws {
    @Schema("""
      {
        "type": ["object", "null"],
        "properties": {
          "values": {"type": ["array", "null"], "items": {"type":"integer"}, "minItems": 1},
          "label": {"type": "string"}
        },
        "required": ["values", "label"],
        "additionalProperties": false
      }
      """)
    enum ContainerSchema {}
    let component = ContainerSchema.schema
    let null = try component.parseAndValidate(instance: "null")
    #expect(null == nil)
    let parsed = try component.parseAndValidate(instance: #"{"values":null,"label":"a"}"#)
    let object = try #require(parsed)
    expectNoDifference(object.values, nil)
    expectNoDifference(object.label, "a")
    for invalid in [#"{"label":"a"}"#, #"{"values":[],"label":"a"}"#, #"{"values":[1],"label":"a","extra":1}"#] {
      #expect(throws: (any Error).self) {
        try component.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func inoutTupleLabel() throws {
    @Schema(
      #"{"type":"object","properties":{"inout":{"type":"string"},"value":{"type":"integer"}},"required":["inout","value"]}"#
    )
    enum KeywordSchema {}
    let value = try KeywordSchema.schema.parseAndValidate(instance: #"{"inout":"a","value":1}"#)
    expectNoDifference(value.inout, "a")
    expectNoDifference(value.value, 1)
  }
}
