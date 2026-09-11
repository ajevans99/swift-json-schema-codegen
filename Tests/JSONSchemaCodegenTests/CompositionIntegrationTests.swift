import CustomDump
import JSONSchemaCodegen
import Testing

struct CompositionIntegrationTests {
  @Test func sameOutputOneOfUsesValidationForBranchSelection() throws {
    @Schema(#"{"oneOf":[{"type":"string","minLength":5},{"type":"string","maxLength":3}]}"#)
    enum TextSchema {}
    expectNoDifference(try TextSchema.schema.parseAndValidate(instance: #""hi""#), "hi")
    expectNoDifference(try TextSchema.schema.parseAndValidate(instance: #""hello""#), "hello")
    #expect(throws: (any Error).self) {
      try TextSchema.schema.parseAndValidate(instance: #""four""#)
    }
  }

  @Test func mixedTypesMapToGeneratedEnumCases() throws {
    @Schema(#"{"oneOf":[{"type":"string"},{"type":"number"},{"type":"null"}]}"#)
    enum TokenSchema {}
    let text = try TokenSchema.schema.parseAndValidate(instance: #""blue""#)
    guard case .option1(let value) = text else { Issue.record("Expected string case"); return }
    expectNoDifference(value, "blue")
    let number = try TokenSchema.schema.parseAndValidate(instance: "12")
    guard case .option2(let value) = number else { Issue.record("Expected number case"); return }
    expectNoDifference(value, 12)
    let null = try TokenSchema.schema.parseAndValidate(instance: "null")
    guard case .option3 = null else { Issue.record("Expected null case"); return }
  }

  @Test func taggedObjectUnionsSelectByConstNotJustObjectParsing() throws {
    @Schema(#"""
      {"oneOf":[
        {"type":"object","properties":{"kind":{"type":"string","const":"ready"},"name":{"type":"string"}},"required":["kind","name"]},
        {"type":"object","properties":{"kind":{"type":"string","const":"pending"},"retry":{"type":"integer"}},"required":["kind","retry"]}
      ]}
      """#)
    enum ResponseSchema {}
    let response = try ResponseSchema.schema.parseAndValidate(instance: #"{"kind":"pending","name":"ignored","retry":5}"#)
    guard case .option2(let pending) = response else { Issue.record("Expected pending case"); return }
    expectNoDifference(pending.retry, 5)
    #expect(throws: (any Error).self) {
      try ResponseSchema.schema.parseAndValidate(instance: #"{"kind":"unknown","name":"ignored","retry":5}"#)
    }
  }

  @Test func nestedAnyOfUsesFirstSchemaValidBranch() throws {
    @Schema(#"""
      {"type":"array","items":{"anyOf":[
        {"type":"object","properties":{"kind":{"type":"string","const":"long"},"name":{"type":"string","minLength":5}},"required":["kind","name"]},
        {"type":"object","properties":{"kind":{"type":"string","const":"short"},"code":{"type":"string","maxLength":3}},"required":["kind","code"]}
      ]}}
      """#)
    enum ResponsesSchema {}
    let responses = try ResponsesSchema.schema.parseAndValidate(instance: #"[{"kind":"short","name":"hello","code":"hi"}]"#)
    guard case .option2(let value) = responses[0] else { Issue.record("Expected short branch"); return }
    expectNoDifference(value.code, "hi")
  }

  @Test func allOfMergesFieldsButRetainsBothConstraints() throws {
    @Schema(#"""
      {"allOf":[
        {"type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string","minLength":3}},"required":["id"]},
        {"properties":{"name":{"maxLength":8},"enabled":{"type":"boolean"}},"required":["name"]}
      ]}
      """#)
    enum ModelSchema {}
    let result = try ModelSchema.schema.parseAndValidate(instance: #"{"id":1,"name":"Style"}"#)
    expectNoDifference(result.id, 1)
    expectNoDifference(result.name, "Style")
    expectNoDifference(result.enabled, nil)
    for invalid in [#"{"id":1,"name":"hi"}"#, #"{"id":1,"name":"a long name"}"#, #"{"name":"Style"}"#] {
      #expect(throws: (any Error).self) { try ModelSchema.schema.parseAndValidate(instance: invalid) }
    }
  }

  @Test func allOfCannotOpenAClosedObject() {
    @Schema(#"""
      {"allOf":[
        {"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],"additionalProperties":false},
        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
      ]}
      """#)
    enum ClosedSchema {}
    #expect(throws: (any Error).self) {
      try ClosedSchema.schema.parseAndValidate(instance: #"{"id":1,"name":"Style"}"#)
    }
  }

  @Test func ambiguityAndNegationAreEnforced() throws {
    @Schema(#"{"oneOf":[{"type":"string","minLength":1},{"type":"string","maxLength":5}]}"#)
    enum AmbiguousSchema {}
    #expect(throws: (any Error).self) { try AmbiguousSchema.schema.parseAndValidate(instance: #""hi""#) }
    @Schema(#"{"type":"string","not":{"const":"blocked"}}"#)
    enum AllowedSchema {}
    expectNoDifference(try AllowedSchema.schema.parseAndValidate(instance: #""allowed""#), "allowed")
    #expect(throws: (any Error).self) { try AllowedSchema.schema.parseAndValidate(instance: #""blocked""#) }
  }

  @Test func allOfWithUnionMergesSharedFieldsIntoEachCase() throws {
    @Schema(#"""
      {"allOf":[
        {"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]},
        {"oneOf":[
          {"type":"object","properties":{"kind":{"type":"string","const":"ready"},"name":{"type":"string"}},"required":["kind","name"]},
          {"type":"object","properties":{"kind":{"type":"string","const":"pending"},"retry":{"type":"integer"}},"required":["kind","retry"]}
        ]}
      ]}
      """#)
    enum ResponseSchema {}
    let response = try ResponseSchema.schema.parseAndValidate(instance: #"{"id":7,"kind":"pending","retry":5}"#)
    guard case .option2(let pending) = response else { Issue.record("Expected pending case"); return }
    expectNoDifference(pending.id, 7)
    expectNoDifference(pending.retry, 5)
    #expect(throws: (any Error).self) {
      try ResponseSchema.schema.parseAndValidate(instance: #"{"kind":"pending","retry":5}"#)
    }
  }

  @Test func unionInsideMergedObjectProjectionKeepsConstraintSelection() throws {
    @Schema(#"""
      {"allOf":[
        {"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]},
        {"properties":{"label":{"oneOf":[{"type":"string","minLength":5},{"type":"string","maxLength":3}]}},"required":["label"]}
      ]}
      """#)
    enum MergedSchema {}
    let value = try MergedSchema.schema.parseAndValidate(instance: #"{"id":1,"label":"hi"}"#)
    expectNoDifference(value.label, "hi")
  }

  @Test func nullableObjectWithUnionPreservesAbsentAndNullProperties() throws {
    @Schema(#"""
      {"type":["object","null"],"properties":{
        "name":{"type":"string"},
        "status":{"oneOf":[{"type":"string","const":"ready"},{"type":"null"}]}
      },"required":["name"]}
      """#)
    enum NullableSchema {}
    #expect(try NullableSchema.schema.parseAndValidate(instance: "null") == nil)
    let parsed = try NullableSchema.schema.parseAndValidate(instance: #"{"name":"Theme","status":null}"#)
    let value = try #require(parsed)
    guard case .option2? = value.status else { Issue.record("Expected present null case"); return }
    let absent = try NullableSchema.schema.parseAndValidate(instance: #"{"name":"Theme"}"#)
    #expect(absent?.status == nil)
  }

  @Test func multipleCompositionKeywordsIntersect() throws {
    @Schema(#"""
      {
        "anyOf":[{"type":"integer","minimum":0},{"type":"string","const":"auto"}],
        "oneOf":[{"type":"integer","maximum":5},{"type":"boolean"}]
      }
      """#)
    enum MultipleCompositionSchema {}
    _ = try MultipleCompositionSchema.schema.parseAndValidate(instance: "3")
    for invalid in ["-1", "6", #""auto""#, "true"] {
      #expect(throws: (any Error).self) { try MultipleCompositionSchema.schema.parseAndValidate(instance: invalid) }
    }
  }

  @Test func booleanAndUnconstrainedUnionBranches() throws {
    @Schema(#"{"oneOf":[true,false]}"#)
    enum BooleanUnionSchema {}
    expectNoDifference(
      try BooleanUnionSchema.schema.parseAndValidate(instance: #"{"arbitrary":[1,true]}"#),
      JSONValue.object(["arbitrary": .array([.integer(1), .boolean(true)])])
    )
    @Schema(#"{"anyOf":[false,{"type":"string"}]}"#)
    enum FallbackSchema {}
    let result = try FallbackSchema.schema.parseAndValidate(instance: #""hello""#)
    guard case .option2(let text) = result else { Issue.record("Expected string branch"); return }
    expectNoDifference(text, "hello")
  }

  @Test func annotatedUnionRetainsItsSchemaAndConstraintsWithoutReplacement() throws {
    @Schema(#"""
      {
        "title":"Font family","description":"A supported font",
        "anyOf":[
          {"type":"string","pattern":"^(Inter|Roboto|Source Sans)$"},
          {"type":"string","pattern":"^(serif|sans-serif|monospace)$"}
        ],
        "default":"Inter","examples":["Inter","serif"],
        "readOnly":true,"writeOnly":false,"deprecated":false,"$comment":"Typography"
      }
      """#)
    enum FontSchema {}
    expectNoDifference(FontSchema.schema.schemaValue, .object([
      "title": .string("Font family"),
      "description": .string("A supported font"),
      "anyOf": .array([
        .object(["type": .string("string"), "pattern": .string("^(Inter|Roboto|Source Sans)$")]),
        .object(["type": .string("string"), "pattern": .string("^(serif|sans-serif|monospace)$")]),
      ]),
      "default": .string("Inter"),
      "examples": .array([.string("Inter"), .string("serif")]),
      "readOnly": .boolean(true), "writeOnly": .boolean(false), "deprecated": .boolean(false),
      "$comment": .string("Typography"),
    ]))
    expectNoDifference(try FontSchema.schema.parseAndValidate(instance: #""Inter""#), "Inter")
    expectNoDifference(try FontSchema.schema.parseAndValidate(instance: #""serif""#), "serif")
    #expect(throws: (any Error).self) {
      try FontSchema.schema.parseAndValidate(instance: #""Comic Sans""#)
    }
  }

  @Test func unionValueConstraintsRemainEffective() throws {
    @Schema(#"""
      {"oneOf":[{"type":"string"},{"type":"integer"}],"enum":["ready",42],"const":"ready"}
      """#)
    enum SelectedSchema {}
    let result = try SelectedSchema.schema.parseAndValidate(instance: #""ready""#)
    guard case .option1(let value) = result else { Issue.record("Expected string case"); return }
    expectNoDifference(value, "ready")
    for invalid in ["42", #""other""#, "43"] {
      #expect(throws: (any Error).self) {
        try SelectedSchema.schema.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func structuralUnionSiblingsStillRestrictValidation() throws {
    @Schema(#"""
      {"anyOf":[{"type":"string"},{"type":"integer"}],"type":"string","minLength":3}
      """#)
    enum RestrictedSchema {}
    _ = try RestrictedSchema.schema.parseAndValidate(instance: #""ready""#)
    for invalid in ["42", #""hi""#] {
      #expect(throws: (any Error).self) {
        try RestrictedSchema.schema.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func adjacentBooleanItemArraysRemainValidBuilderExpressions() throws {
    @Schema(#"{"anyOf":[{"type":"array","items":false},{"type":"array","items":true}]}"#)
    enum ArraysSchema {}
    expectNoDifference(try ArraysSchema.schema.parseAndValidate(instance: "[]"), [JSONValue]())
    expectNoDifference(try ArraysSchema.schema.parseAndValidate(instance: "[1]"), [.integer(1)])
  }
}
