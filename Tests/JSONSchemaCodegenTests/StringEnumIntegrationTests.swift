import CustomDump
import JSONSchemaCodegen
import Testing

@Schema(
  #"{"type":"string","enum":["draft","in-progress","done"]}"#, output: .models)
private enum StringStatus {}

@Schema(#"{"type":"string","enum":["draft","in-progress","done"]}"#)
private enum StringStatusTuples {}

@Schema(
  #"{"enum":["é","e\u0301","","a-b","a_b","123","class","rawValue","hash","\"","\\","line\nend","\u0000","é"]}"#,
  output: .models,
  caseNames: [
    "#/enum/0": "composed", "#/enum/1": "decomposed", "#/enum/2": "empty",
    "#/enum/3": "hyphen", "#/enum/4": "underscore", "#/enum/9": "quote",
    "#/enum/10": "backslash", "#/enum/11": "newline", "#/enum/12": "nul",
  ])
private enum ExactStringEnum {}

@Schema(
  #"{"enum":["é","e\u0301","","a-b","a_b","123","class","rawValue","hash","\"","\\","line\nend","\u0000","é"]}"#
)
private enum ExactStringEnumTuples {}

@Schema(#"{"type":"string","enum":["é"]}"#, output: .models)
private enum OnlyComposedEnum {}

@Schema(#"{"type":"string","enum":["é"]}"#)
private enum OnlyComposedEnumTuples {}

@Schema(#"{"enum":["draft",null]}"#, output: .models)
private enum InferredNullableEnum {}

@Schema(#"{"enum":["draft",null]}"#)
private enum InferredNullableEnumTuples {}

@Schema(
  ##"""
  {"type":"object","$defs":{"Status":{"type":"string","enum":["draft","done"]}},
   "properties":{"required":{"$ref":"#/$defs/Status"},"optional":{"$ref":"#/$defs/Status"},
     "requiredNullable":{"type":["string","null"],"enum":["draft","done",null]},
     "optionalNullable":{"type":["string","null"],"enum":["draft","done",null]},
     "items":{"type":"array","items":{"$ref":"#/$defs/Status"}}},
   "required":["required","requiredNullable","items"],"additionalProperties":{"$ref":"#/$defs/Status"}}
  """##,
  output: .models)
private enum EnumFields {}

@Schema(
  ##"""
  {"type":"object","$defs":{"Status":{"type":"string","enum":["draft","done"]}},
   "properties":{"required":{"$ref":"#/$defs/Status"},"optional":{"$ref":"#/$defs/Status"},
     "requiredNullable":{"type":["string","null"],"enum":["draft","done",null]},
     "optionalNullable":{"type":["string","null"],"enum":["draft","done",null]},
     "items":{"type":"array","items":{"$ref":"#/$defs/Status"}}},
   "required":["required","requiredNullable","items"],"additionalProperties":{"$ref":"#/$defs/Status"}}
  """##)
private enum EnumFieldsTuples {}

@Schema(
  #"{"allOf":[{"enum":["draft","done","retired"]},{"type":"string","enum":["draft","done"]},{"const":"done"}]}"#,
  output: .models)
private enum IntersectedEnum {}

@Schema(
  #"{"allOf":[{"enum":["draft","done","retired"]},{"type":"string","enum":["draft","done"]},{"const":"done"}]}"#
)
private enum IntersectedEnumTuples {}

@Schema(
  #"{"anyOf":[{"enum":["draft"]},{"type":"string"},{"type":"integer"}]}"#,
  output: .models, typeNames: ["#/anyOf/0": "Status"])
private enum EnumOrString {}

@Schema(#"{"anyOf":[{"enum":["draft"]},{"type":"string"},{"type":"integer"}]}"#)
private enum EnumOrStringTuples {}

@Schema(
  #"{"oneOf":[{"type":"string","enum":["draft","shared"]},{"type":"string","enum":["done","shared"]}]}"#,
  output: .models, typeNames: ["#/oneOf/0": "Draft", "#/oneOf/1": "Done"])
private enum EnumOneOf {}

@Schema(
  #"{"oneOf":[{"type":"string","enum":["draft","shared"]},{"type":"string","enum":["done","shared"]}]}"#
)
private enum EnumOneOfTuples {}

@Schema(
  ##"""
  {"type":"object","$defs":{"Status":{"type":"string","enum":["draft","done"]},"Text":{"type":"string"}},
   "properties":{"plain":{"$ref":"#/$defs/Status"},"refined":{"$ref":"#/$defs/Status","enum":["done"]},
     "bounded":{"$ref":"#/$defs/Text","enum":["draft"]},"pattern":{"$ref":"#/$defs/Status","pattern":"^d"}},
   "required":["plain","refined","bounded","pattern"]}
  """##,
  output: .models,
  caseNames: ["#/properties/refined/enum/0": "completed"])
private enum RefinedEnumFields {}

@Schema(
  ##"""
  {"type":"object","$defs":{"Status":{"type":"string","enum":["draft","done"]},"Text":{"type":"string"}},
   "properties":{"plain":{"$ref":"#/$defs/Status"},"refined":{"$ref":"#/$defs/Status","enum":["done"]},
     "bounded":{"$ref":"#/$defs/Text","enum":["draft"]},"pattern":{"$ref":"#/$defs/Status","pattern":"^d"}},
   "required":["plain","refined","bounded","pattern"]}
  """##)
private enum RefinedEnumFieldsTuples {}

@Schema(
  #"{"enum":["draft",1,null],"type":["string","integer","null"]}"#, output: .models)
private enum MixedStringEnum {}

@Schema(#"{"enum":["draft",1,null],"type":["string","integer","null"]}"#)
private enum MixedStringEnumTuples {}

@Schema(#"{"type":"string","enum":[]}"#, output: .models)
private enum EmptyStringEnum {}

@Schema(#"{"type":"string","enum":[]}"#)
private enum EmptyStringEnumTuples {}

@Schema(
  #"{"enum":["draft","done"],"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
  output: .models)
private enum EnumUnionSibling {}

@Schema(#"{"enum":["draft","done"],"anyOf":[{"type":"string"},{"type":"integer"}]}"#)
private enum EnumUnionSiblingTuples {}

@Schema(
  #"{"allOf":[{"anyOf":[{"enum":["draft"]},{"enum":["done"]}]},{"type":"string"}]}"#,
  output: .models)
private enum ComposedEnumUnion {}

@Schema(#"{"allOf":[{"anyOf":[{"enum":["draft"]},{"enum":["done"]}]},{"type":"string"}]}"#)
private enum ComposedEnumUnionTuples {}

@Schema(
  ##"""
  {"anyOf":[{"type":"string","enum":["end"]},{"type":"array","items":{"$ref":"#","enum":["end"]}}]}
  """##,
  output: .models,
  typeNames: ["#/anyOf/0": "Terminal"])
private enum RecursiveEnumUnion {}

@Schema(
  ##"""
  {"anyOf":[{"type":"string","enum":["end"]},{"type":"array","items":{"$ref":"#","enum":["end"]}}]}
  """##)
private enum RecursiveEnumUnionTuples {}

struct StringEnumIntegrationTests {
  private func parity<A: JSONSchemaComponent, B: JSONSchemaComponent>(
    _ models: A, _ tuples: B, _ examples: [(String, Bool)]
  ) throws {
    expectNoDifference(models.schemaValue, tuples.schemaValue)
    for (source, valid) in examples {
      let value = try JSONValue.parse(source)
      expectNoDifference(models.definition().validate(value).isValid, valid)
      expectNoDifference(tuples.definition().validate(value).isValid, valid)
      if valid {
        _ = try models.parseAndValidate(value)
        _ = try tuples.parseAndValidate(value)
      } else {
        #expect(throws: (any Error).self) { try models.parseAndValidate(value) }
        #expect(throws: (any Error).self) { try tuples.parseAndValidate(value) }
      }
    }
  }

  @Test func simpleRawStringInteroperability() throws {
    let value: StringStatus.Value = try StringStatus.schema.parseAndValidate(
      instance: #""in-progress""#)
    expectNoDifference(value, .inProgress)
    expectNoDifference(value.rawValue, "in-progress")
    expectNoDifference(StringStatus.Value(rawValue: "draft"), .draft)
    #expect(StringStatus.Value(rawValue: "unknown") == nil)
    guard case .invalid = StringStatus.schema.parse(.string("unknown")) else {
      Issue.record("Unmappable values must be explicit parse failures.")
      return
    }
    let legacy: String = try StringStatusTuples.schema.parseAndValidate(instance: #""done""#)
    expectNoDifference(legacy, "done")
    try parity(
      StringStatus.schema, StringStatusTuples.schema,
      [
        (#""draft""#, true), (#""in-progress""#, true), (#""done""#, true),
        (#""unknown""#, false), ("null", false), ("1", false),
      ])
  }

  @Test func exactUnicodeConversionEqualityHashingAndEscapes() throws {
    let values = [
      "é", "e\u{301}", "", "a-b", "a_b", "123", "class", "rawValue", "hash",
      "\"", "\\", "line\nend", "\0",
    ]
    for raw in values {
      let constructed = try #require(ExactStringEnum.Value(rawValue: raw))
      let parsed = try ExactStringEnum.schema.parseAndValidate(.string(raw))
      expectNoDifference(parsed, constructed)
      expectNoDifference(Array(parsed.rawValue.unicodeScalars), Array(raw.unicodeScalars))
      _ = try ExactStringEnumTuples.schema.parseAndValidate(.string(raw))
    }
    expectNoDifference(ExactStringEnum.Value(rawValue: "é"), .composed)
    expectNoDifference(ExactStringEnum.Value(rawValue: "e\u{301}"), .decomposed)
    #expect(ExactStringEnum.Value.composed != .decomposed)
    expectNoDifference(Set([ExactStringEnum.Value.composed, .decomposed]).count, 2)
    expectNoDifference(ExactStringEnum.Value.empty.rawValue, "")
    expectNoDifference(ExactStringEnum.Value.class.rawValue, "class")
    expectNoDifference(ExactStringEnum.Value.alternative123.rawValue, "123")
    expectNoDifference(ExactStringEnum.schema.schemaValue, ExactStringEnumTuples.schema.schemaValue)
    #expect(OnlyComposedEnum.Value(rawValue: "e\u{301}") == nil)
    try parity(
      OnlyComposedEnum.schema, OnlyComposedEnumTuples.schema,
      [
        (#""é""#, true), (#""\u00e9""#, true), (#""e\u0301""#, false), (#""É""#, false),
      ])
  }

  @Test func nullableAndAbsenceSemantics() throws {
    let value: InferredNullableEnum.Value = .draft
    expectNoDifference(value?.rawValue, "draft")
    try parity(
      InferredNullableEnum.schema, InferredNullableEnumTuples.schema,
      [
        ("null", true), (#""draft""#, true), (#""done""#, false), ("1", false),
      ])
    let absent = try EnumFields.schema.parseAndValidate(
      instance:
        #"{"required":"draft","requiredNullable":null,"items":["draft","done"],"extra":"done"}"#)
    let _: EnumFields.Status = absent.required
    expectNoDifference(absent.required, .draft)
    expectNoDifference(absent.items, [.draft, .done])
    expectNoDifference(absent.additionalProperties["extra"], .done)
    #expect(absent.requiredNullable == nil)
    #expect(absent.optionalNullable == nil)
    let explicitNull = try EnumFields.schema.parseAndValidate(
      instance:
        #"{"required":"draft","requiredNullable":"done","optionalNullable":null,"items":[]}"#)
    guard case .some(.none) = explicitNull.optionalNullable else {
      Issue.record("Optional enum null must not become absence.")
      return
    }
    expectNoDifference(explicitNull.requiredNullable, .done)
    let constructed = EnumFields.Value(
      required: .draft, requiredNullable: nil, items: [.done], additionalProperties: [:])
    #expect(constructed.optional == nil)
    #expect(constructed.optionalNullable == nil)
    try parity(
      EnumFields.schema, EnumFieldsTuples.schema,
      [
        (#"{"required":"done","requiredNullable":null,"items":[]}"#, true),
        (
          #"{"required":"draft","requiredNullable":"done","optionalNullable":null,"items":["draft"]}"#,
          true
        ),
        (#"{"required":"done","items":[]}"#, false),
        (#"{"required":"done","requiredNullable":null,"items":["unknown"]}"#, false),
        (#"{"required":"done","requiredNullable":null,"items":[],"extra":"unknown"}"#, false),
      ])
  }

  @Test func compositionBoundsNeverReplaceValidation() throws {
    // Constructors expose the finite bound, not all intersected validation constraints.
    expectNoDifference(IntersectedEnum.Value.retired.rawValue, "retired")
    let parsed = try IntersectedEnum.schema.parseAndValidate(instance: #""done""#)
    expectNoDifference(parsed, .done)
    try parity(
      IntersectedEnum.schema, IntersectedEnumTuples.schema,
      [
        (#""done""#, true), (#""draft""#, false), (#""retired""#, false), ("null", false),
      ])
    try parity(
      EnumOrString.schema, EnumOrStringTuples.schema,
      [
        (#""draft""#, true), (#""arbitrary""#, true), ("1", true), ("false", false),
      ])
    guard case .status(.draft) = try EnumOrString.schema.parseAndValidate(instance: #""draft""#),
      case .string("arbitrary") = try EnumOrString.schema.parseAndValidate(
        instance: #""arbitrary""#)
    else {
      Issue.record("anyOf order or unbounded string alternative changed.")
      return
    }
    try parity(
      EnumOneOf.schema, EnumOneOfTuples.schema,
      [
        (#""draft""#, true), (#""done""#, true), (#""shared""#, false), (#""unknown""#, false),
      ])
    guard case .draft(.draft) = try EnumOneOf.schema.parseAndValidate(instance: #""draft""#) else {
      Issue.record("oneOf must expose its typed enum payload.")
      return
    }
  }

  @Test func referenceRefinementsRetainNominalModelsAndValidation() throws {
    let result = try RefinedEnumFields.schema.parseAndValidate(
      instance: #"{"plain":"draft","refined":"done","bounded":"draft","pattern":"done"}"#)
    let _: RefinedEnumFields.Status = result.plain
    let _: RefinedEnumFields.Status = result.pattern
    let _: RefinedEnumFields.Refined = result.refined
    let _: RefinedEnumFields.Bounded = result.bounded
    expectNoDifference(result.refined.rawValue, "done")
    expectNoDifference(result.refined, .completed)
    try parity(
      RefinedEnumFields.schema, RefinedEnumFieldsTuples.schema,
      [
        (#"{"plain":"draft","refined":"done","bounded":"draft","pattern":"done"}"#, true),
        (#"{"plain":"draft","refined":"draft","bounded":"draft","pattern":"done"}"#, false),
        (#"{"plain":"draft","refined":"done","bounded":"other","pattern":"done"}"#, false),
      ])
  }

  @Test func excludedEnumShapesKeepLegacyRepresentation() throws {
    let empty: EmptyStringEnum.Value = "still a String"
    expectNoDifference(empty, "still a String")
    try parity(EmptyStringEnum.schema, EmptyStringEnumTuples.schema, [(#""anything""#, false)])
    try parity(
      MixedStringEnum.schema, MixedStringEnumTuples.schema,
      [
        (#""draft""#, true), ("1", true), ("null", true), (#""done""#, false), ("1.5", false),
      ])
    guard case .string("draft") = try MixedStringEnum.schema.parseAndValidate(instance: #""draft""#)
    else {
      Issue.record("Mixed-type enum string payload must remain String.")
      return
    }
  }

  @Test func positiveBoundsCrossUnionsWithoutChangingTheirSchemas() throws {
    let examples = [(#""draft""#, true), (#""done""#, true), (#""other""#, false), ("1", false)]
    try parity(EnumUnionSibling.schema, EnumUnionSiblingTuples.schema, examples)
    try parity(ComposedEnumUnion.schema, ComposedEnumUnionTuples.schema, examples)
  }

  @Test func recursiveAdaptersSupportEnumRefinements() throws {
    guard case .terminal(.end) = try RecursiveEnumUnion.schema.parseAndValidate(instance: #""end""#)
    else {
      Issue.record("Recursive union string payload is not the public enum.")
      return
    }
    try parity(
      RecursiveEnumUnion.schema, RecursiveEnumUnionTuples.schema,
      [
        (#""end""#, true), (#"["end"]"#, true), (#"[["end"]]"#, false),
        (#"["unknown"]"#, false), ("[]", true), ("1", false),
      ])
  }
}
