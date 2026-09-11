import CustomDump
import JSONSchemaCodegen
import Testing

struct SyntaxIntegrationTests {
  @Test func numericLiteralExtremesCompileWithoutChangingValues() throws {
    @Schema(#"{"type":"integer","const":-9223372036854775808}"#)
    enum MinimumSchema {}
    expectNoDifference(try MinimumSchema.schema.parseAndValidate(.integer(Int.min)), Int.min)

    @Schema(#"{"type":"number","const":1.7976931348623157e308}"#)
    enum MaximumSchema {}
    expectNoDifference(
      try MaximumSchema.schema.parseAndValidate(.number(.greatestFiniteMagnitude)),
      Double.greatestFiniteMagnitude
    )
  }

  @Test func generatedRawStringsPreserveScalarsAtRuntime() throws {
    @Schema(
      ####"""
      {
        "type":"string",
        "const":"\"\u0301\\\u0301 \"### \\###(notInterpolation) \u0000\r\n\t\u007f\u0085\u2028\u2029 cafe\u0301"
      }
      """####)
    enum LiteralSchema {}
    let value =
      "\"\u{301}\\\u{301} \"### \\###(notInterpolation) \0\r\n\t\u{7f}\u{85}\u{2028}\u{2029} cafe\u{301}"
    expectNoDifference(
      LiteralSchema.schema.schemaValue.object?["const"]?.string?.unicodeScalars.map(\.value),
      value.unicodeScalars.map(\.value)
    )
    let parsed = try LiteralSchema.schema.parseAndValidate(.string(value))
    expectNoDifference(parsed.unicodeScalars.map(\.value), value.unicodeScalars.map(\.value))
  }

  @Test func generatedKeywordTupleLabelsCompileAndPreservePresence() throws {
    @Schema(
      #"""
      {
        "type":"object",
        "properties":{
          "inout":{"type":"integer"},
          "default":{"type":["string","null"]},
          "self":{"type":"boolean"},
          "Type":{"type":"string"},
          "async":{"type":"string"}
        },
        "required":["inout","self","Type","async"]
      }
      """#)
    enum KeywordsSchema {}
    let value = try KeywordsSchema.schema.parseAndValidate(
      instance: #"""
        {"inout":1,"self":true,"Type":"type","async":"async","default":null}
        """#)
    let integer: Int = value.inout
    let nullable: String?? = value.default
    expectNoDifference(integer, 1)
    expectNoDifference(nullable, .some(nil))
    expectNoDifference(value.`self`, true)
    expectNoDifference(value.Type, "type")
    expectNoDifference(value.async, "async")
  }

  @Test func nestedBooleanArrayClosuresKeepTheirReturnTypesAndItems() throws {
    @Schema(
      #"""
      {"type":"array","items":{"anyOf":[
        {"type":"array","items":false},
        {"type":"array","items":true}
      ]}}
      """#)
    enum ArraysSchema {}
    let values: [[JSONValue]] = try ArraysSchema.schema.parseAndValidate(instance: "[[],[1]]")
    expectNoDifference(values, [[], [.integer(1)]])

    @Schema(#"{"type":"array","items":{"type":"array","items":false}}"#)
    enum EmptyArraysSchema {}
    expectNoDifference(
      try EmptyArraysSchema.schema.parseAndValidate(instance: "[[]]"), [[JSONValue]()]
    )
    #expect(throws: (any Error).self) {
      try EmptyArraysSchema.schema.parseAndValidate(instance: "[[1]]")
    }
  }

  @Test func nestedTuplePayloadEnumsRemainSendable() throws {
    @Schema(
      #"""
      {"oneOf":[
        {"type":"object","properties":{"class":{"type":"string"},"value":{"type":["integer","null"]}},"required":["class"]},
        {"type":"array","items":{"oneOf":[{"type":"integer"},{"type":"boolean"}]}}
      ]}
      """#)
    enum NestedSchema {}
    func requireSendable<Value: Sendable>(_ value: Value) -> Value { value }
    let result = requireSendable(
      try NestedSchema.schema.parseAndValidate(instance: #"{"class":"text","value":null}"#))
    guard case .option1(let payload) = result else {
      Issue.record("Expected the object payload")
      return
    }
    expectNoDifference(payload.class, "text")
    expectNoDifference(payload.value, Optional<Int?>.some(nil))
  }
}
