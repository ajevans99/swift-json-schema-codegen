import CustomDump
import JSONSchemaCodegen
import Testing

struct KeywordIntegrationTests {
  @Test func typeArraysHaveTypedCasesAndDoNotInferKeywordTypes() throws {
    @Schema(#"{"type":["string","integer","boolean"],"minLength":2,"minimum":0}"#)
    enum ValueSchema {}
    guard case .option1(let string) = try ValueSchema.schema.parseAndValidate(instance: #""hi""#)
    else {
      Issue.record("Expected string case")
      return
    }
    expectNoDifference(string, "hi")
    guard case .option2(let integer) = try ValueSchema.schema.parseAndValidate(instance: "3")
    else {
      Issue.record("Expected integer case")
      return
    }
    expectNoDifference(integer, 3)
    guard case .option3(let boolean) = try ValueSchema.schema.parseAndValidate(instance: "true")
    else {
      Issue.record("Expected boolean case")
      return
    }
    expectNoDifference(boolean, true)
    for invalid in [#""x""#, "-1", "null", "[]"] {
      #expect(throws: (any Error).self) {
        try ValueSchema.schema.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func typeSpecificKeywordsWithoutTypesDoNotImplyTypes() throws {
    @Schema(#"{"minLength":3,"properties":{"name":{"type":"string"}},"required":["name"]}"#)
    enum UnconstrainedSchema {}
    expectNoDifference(
      try UnconstrainedSchema.schema.parseAndValidate(instance: "42"), .integer(42))
    expectNoDifference(try UnconstrainedSchema.schema.parseAndValidate(instance: "[]"), .array([]))
    expectNoDifference(
      try UnconstrainedSchema.schema.parseAndValidate(instance: #""long""#), .string("long"))
    for invalid in [#""hi""#, "{}", #"{"name":1}"#] {
      #expect(throws: (any Error).self) {
        try UnconstrainedSchema.schema.parseAndValidate(instance: invalid)
      }
    }
    @Schema(#"{"type":"string","minimum":10,"items":false}"#)
    enum StringSchema {}
    expectNoDifference(try StringSchema.schema.parseAndValidate(instance: #""text""#), "text")
  }

  @Test func typedAdditionalPropertiesHaveAnExplicitShape() throws {
    @Schema(#"{"type":"object","additionalProperties":{"type":"integer"}}"#)
    enum DictionarySchema {}
    expectNoDifference(
      try DictionarySchema.schema.parseAndValidate(instance: #"{"a":1,"type":2}"#),
      ["a": 1, "type": 2]
    )
    #expect(throws: (any Error).self) {
      try DictionarySchema.schema.parseAndValidate(instance: #"{"a":"wrong"}"#)
    }

    @Schema(
      #"""
      {"type":"object","properties":{"name":{"type":"string"},"count":{"type":"integer"}},
       "required":["name","count"],"additionalProperties":{"type":"string"}}
      """#)
    enum NamedSchema {}
    let parsed = try NamedSchema.schema.parseAndValidate(
      instance: #"{"name":"first","count":1,"type":"extra","other":"value"}"#)
    expectNoDifference(parsed.properties.name, "first")
    expectNoDifference(parsed.properties.count, 1)
    expectNoDifference(parsed.additionalProperties, ["type": "extra", "other": "value"])
  }

  @Test func patternPropertiesAreNotAdditionalProperties() throws {
    @Schema(
      #"""
      {"type":"object","properties":{"name":{"type":"string"}},
       "patternProperties":{"^n":{"type":"string"}},
       "additionalProperties":{"type":"integer"},"required":["name"]}
      """#)
    enum PatternSchema {}
    let parsed = try PatternSchema.schema.parseAndValidate(
      instance: #"{"name":"first","note":"pattern","extra":2}"#)
    expectNoDifference(parsed.properties, "first")
    expectNoDifference(parsed.additionalProperties, ["extra": 2])
    #expect(throws: (any Error).self) {
      try PatternSchema.schema.parseAndValidate(instance: #"{"name":"first","note":42}"#)
    }
  }

  @Test func requiredUndeclaredNamesAreJSONValuesAndDoNotBecomeEvaluated() throws {
    @Schema(#"{"type":"object","required":["undeclared"]}"#)
    enum RequiredSchema {}
    expectNoDifference(
      try RequiredSchema.schema.parseAndValidate(instance: #"{"undeclared":[1]}"#),
      .array([.integer(1)])
    )
    #expect(throws: (any Error).self) { try RequiredSchema.schema.parseAndValidate(instance: "{}") }
    @Schema(#"{"type":"object","required":["undeclared"],"unevaluatedProperties":false}"#)
    enum ClosedSchema {}
    #expect(throws: (any Error).self) {
      try ClosedSchema.schema.parseAndValidate(instance: #"{"undeclared":1}"#)
    }
  }

  @Test func prefixEntriesNeverUseTheTailParser() throws {
    @Schema(
      #"""
      {"type":"array","prefixItems":[{"type":"string"},{"type":"integer"}],
       "items":{"type":"boolean"}}
      """#)
    enum PrefixSchema {}
    expectNoDifference(
      try PrefixSchema.schema.parseAndValidate(instance: #"["prefix",2,true]"#),
      [.string("prefix"), .integer(2), .boolean(true)]
    )
    expectNoDifference(
      try PrefixSchema.schema.parseAndValidate(instance: #"["prefix"]"#), [.string("prefix")])
    for invalid in [#"[1,2]"#, #"["prefix","wrong"]"#, #"["prefix",2,3]"#] {
      #expect(throws: (any Error).self) {
        try PrefixSchema.schema.parseAndValidate(instance: invalid)
      }
    }
    @Schema(#"{"type":"array","prefixItems":[{"type":"integer"}],"items":false}"#)
    enum ClosedPrefixSchema {}
    expectNoDifference(
      try ClosedPrefixSchema.schema.parseAndValidate(instance: "[1]"), [.integer(1)])
    #expect(throws: (any Error).self) {
      try ClosedPrefixSchema.schema.parseAndValidate(instance: "[1,2]")
    }
  }

  @Test func containsBoundsAndUnevaluatedItemsAreEnforced() throws {
    @Schema(
      #"""
      {"type":"array","prefixItems":[{"type":"string"}],
       "contains":{"type":"integer"},"minContains":1,"maxContains":2,
       "unevaluatedItems":false}
      """#)
    enum ArraySchema {}
    expectNoDifference(
      try ArraySchema.schema.parseAndValidate(instance: #"["prefix",1,2]"#),
      [.string("prefix"), .integer(1), .integer(2)]
    )
    for invalid in [#"["prefix"]"#, #"["prefix",1,2,3]"#, #"["prefix",1,true]"#] {
      #expect(throws: (any Error).self) {
        try ArraySchema.schema.parseAndValidate(instance: invalid)
      }
    }
    @Schema(#"{"type":"array","contains":false,"minContains":0}"#)
    enum EmptyContainsSchema {}
    expectNoDifference(
      try EmptyContainsSchema.schema.parseAndValidate(instance: "[1]"), [.integer(1)])
  }

  @Test func dependenciesAndPropertyNamesRemainValidationOnly() throws {
    @Schema(
      #"""
      {"type":"object","properties":{"name":{"type":"string"},"count":{"type":"integer"}},
       "propertyNames":{"pattern":"^[a-z]+$"},"dependentRequired":{"name":["count"]},
       "dependentSchemas":{"count":{"properties":{"count":{"minimum":1}}}},
       "unevaluatedProperties":false}
      """#)
    enum DependentSchema {}
    let parsed = try DependentSchema.schema.parseAndValidate(
      instance: #"{"name":"sample","count":2}"#)
    expectNoDifference(parsed.name, "sample")
    expectNoDifference(parsed.count, 2)
    for invalid in [#"{"name":"sample"}"#, #"{"count":0}"#, #"{"COUNT":1}"#, #"{"extra":1}"#] {
      #expect(throws: (any Error).self) {
        try DependentSchema.schema.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func conditionalsValidateWithoutChangingProjection() throws {
    @Schema(
      #"""
      {"type":"object","properties":{"mode":{"type":"string"},"value":{"type":"integer"}},
       "required":["mode","value"],"if":{"properties":{"mode":{"const":"large"}}},
       "then":{"properties":{"value":{"minimum":10}}},
       "else":{"properties":{"value":{"maximum":5}}}}
      """#)
    enum ConditionalSchema {}
    expectNoDifference(
      try ConditionalSchema.schema.parseAndValidate(instance: #"{"mode":"large","value":12}"#)
        .value,
      12
    )
    expectNoDifference(
      try ConditionalSchema.schema.parseAndValidate(instance: #"{"mode":"small","value":3}"#).value,
      3
    )
    for invalid in [#"{"mode":"large","value":1}"#, #"{"mode":"small","value":12}"#] {
      #expect(throws: (any Error).self) {
        try ConditionalSchema.schema.parseAndValidate(instance: invalid)
      }
    }
  }

  @Test func enumAllowsEmptyAndDuplicateArrays() throws {
    @Schema(#"{"enum":[]}"#)
    enum EmptySchema {}
    for value in ["null", "1", #""text""#, "{}", "[]", "false"] {
      #expect(throws: (any Error).self) { try EmptySchema.schema.parseAndValidate(instance: value) }
    }
    @Schema(#"{"type":"integer","enum":[1,1.0]}"#)
    enum DuplicateSchema {}
    expectNoDifference(try DuplicateSchema.schema.parseAndValidate(instance: "1"), 1)
  }

  @Test func contentAndExtensionAnnotationsAreNotAssertions() throws {
    @Schema(
      #"""
      {"type":"string","contentEncoding":"base64","contentMediaType":"application/json",
       "contentSchema":{"type":"integer"},"x-arbitrary":{"$ref":"not-a-reference","type":17}}
      """#)
    enum ContentSchema {}
    expectNoDifference(
      try ContentSchema.schema.parseAndValidate(instance: #""not base64!""#), "not base64!")
    expectNoDifference(
      ContentSchema.schema.schemaValue["x-arbitrary"],
      .object([
        "$ref": .string("not-a-reference"), "type": .integer(17),
      ]))
    expectNoDifference(
      ContentSchema.schema.schemaValue["contentSchema"], .object(["type": .string("integer")]))
  }

  @Test func typeIntersectionPreservesAllRemainingDomains() throws {
    @Schema(#"{"allOf":[{"type":["string","integer","boolean"]},{"type":["boolean","string"]}]}"#)
    enum IntersectionSchema {}
    _ = try IntersectionSchema.schema.parseAndValidate(instance: #""text""#)
    _ = try IntersectionSchema.schema.parseAndValidate(instance: "true")
    #expect(throws: (any Error).self) {
      try IntersectionSchema.schema.parseAndValidate(instance: "1")
    }
  }

  @Test func standardVocabularyAndArbitraryAnnotationsAllowTypedProjection() throws {
    @Schema(
      #"""
      {"$vocabulary":{
        "https://json-schema.org/draft/2020-12/vocab/core":true,
        "https://json-schema.org/draft/2020-12/vocab/applicator":true,
        "https://json-schema.org/draft/2020-12/vocab/validation":true,
        "https://json-schema.org/draft/2020-12/vocab/unevaluated":true,
        "https://json-schema.org/draft/2020-12/vocab/meta-data":true,
        "https://json-schema.org/draft/2020-12/vocab/format-annotation":true,
        "https://json-schema.org/draft/2020-12/vocab/content":true
       },
       "type":["string","integer"],
       "x-annotation":{"$ref":"not-a-reference","$vocabulary":17}}
      """#)
    enum VocabularySchema {}
    guard
      case .option1(let string) = try VocabularySchema.schema.parseAndValidate(instance: #""text""#)
    else {
      Issue.record("Expected string case")
      return
    }
    expectNoDifference(string, "text")
    guard case .option2(let number) = try VocabularySchema.schema.parseAndValidate(instance: "2")
    else {
      Issue.record("Expected integer case")
      return
    }
    expectNoDifference(number, 2)
  }

  @Test func standardVocabularySubsetsSupportTheirOwnKeywords() throws {
    @Schema(
      #"""
      {"$vocabulary":{
        "https://json-schema.org/draft/2020-12/vocab/core":true,
        "https://json-schema.org/draft/2020-12/vocab/applicator":true,
        "https://json-schema.org/draft/2020-12/vocab/validation":true
       },
       "type":["string","integer"]}
      """#)
    enum VocabularySchema {}
    guard case .option2(let integer) = try VocabularySchema.schema.parseAndValidate(instance: "2")
    else {
      Issue.record("Expected integer case")
      return
    }
    expectNoDifference(integer, 2)
  }

  @Test func requiredOnlyFieldsStillBelongToAdditionalProperties() throws {
    @Schema(#"{"type":"object","required":["type"],"additionalProperties":{"type":"integer"}}"#)
    enum RequiredDictionarySchema {}
    let result = try RequiredDictionarySchema.schema.parseAndValidate(
      instance: #"{"type":1,"other":2}"#)
    expectNoDifference(result.properties, .integer(1))
    expectNoDifference(result.additionalProperties, ["type": 1, "other": 2])
  }

  @Test func nullableEnumsStillRejectNullWhenItIsNotListed() {
    @Schema(#"{"type":["string","null"],"enum":[]}"#)
    enum EmptyNullableSchema {}
    #expect(throws: (any Error).self) {
      try EmptyNullableSchema.schema.parseAndValidate(instance: "null")
    }
    @Schema(#"{"type":["string","null"],"enum":["allowed"]}"#)
    enum NullableSchema {}
    #expect(throws: (any Error).self) {
      try NullableSchema.schema.parseAndValidate(instance: "null")
    }
  }

  @Test func intersectionsRetainTypedAdditionalValues() throws {
    @Schema(
      #"""
      {"allOf":[
        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},
        {"additionalProperties":{"type":"string","minLength":2}}
      ]}
      """#)
    enum IntersectionSchema {}
    let result = try IntersectionSchema.schema.parseAndValidate(
      instance: #"{"name":"declared","other":"extra"}"#)
    expectNoDifference(result.properties, "declared")
    expectNoDifference(result.additionalProperties, ["other": "extra"])
    #expect(throws: (any Error).self) {
      try IntersectionSchema.schema.parseAndValidate(instance: #"{"name":"declared","other":"x"}"#)
    }
  }

  @Test func additionalPropertyUnionsKeepTypedBranchSelection() throws {
    @Schema(
      #"""
      {"type":"object","additionalProperties":{"anyOf":[
        {"type":"string","minLength":3},{"type":"integer","minimum":1}
      ]}}
      """#)
    enum DictionarySchema {}
    let result = try DictionarySchema.schema.parseAndValidate(
      instance: #"{"text":"value","number":2}"#)
    guard case .option1(let string)? = result["text"] else {
      Issue.record("Expected string case")
      return
    }
    expectNoDifference(string, "value")
    guard case .option2(let number)? = result["number"] else {
      Issue.record("Expected integer case")
      return
    }
    expectNoDifference(number, 2)
    #expect(throws: (any Error).self) {
      try DictionarySchema.schema.parseAndValidate(instance: #"{"text":"x"}"#)
    }
  }

  @Test func intersectionTailConstraintsNeverParseThePrefix() throws {
    @Schema(
      #"""
      {"allOf":[
        {"type":"array","prefixItems":[{"type":"integer"}],"items":{"type":"string"}},
        {"items":{"type":["integer","string"]}}
      ]}
      """#)
    enum IntersectionSchema {}
    expectNoDifference(
      try IntersectionSchema.schema.parseAndValidate(instance: #"[1,"tail"]"#),
      [.integer(1), .string("tail")]
    )
  }
}
