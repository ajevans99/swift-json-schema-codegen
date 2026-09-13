import CustomDump
import JSONSchemaCodegen
import Testing

@Schema(
  #"""
  {
    "type":"object",
    "properties":{
      "$id":{"type":"string"},
      "id":{"type":"integer"},
      "a-b":{"type":"boolean"},
      "a_b":{"type":"string"},
      "":{"type":"integer"},
      "_":{"type":"string"},
      "inout":{"type":"boolean"},
      "class":{"type":"string"}
    },
    "required":["$id","id","a_b","","inout","class"],
    "additionalProperties":false
  }
  """#)
private enum PropertyNamingFixture {}

struct PropertyNamingIntegrationTests {
  @Test func arbitraryKeysProduceUsableTypedLabels() throws {
    let value = try PropertyNamingFixture.schema.parseAndValidate(
      instance: #"""
        {"$id":"identifier","id":42,"a-b":true,"a_b":"original","":7,"_":"underscore",
         "inout":false,"class":"keyword"}
        """#)
    expectNoDifference(value.id_2, "identifier")
    expectNoDifference(value.id, 42)
    expectNoDifference(value.a_b_2, true)
    expectNoDifference(value.a_b, "original")
    expectNoDifference(value.property, 7)
    expectNoDifference(value.property_2, "underscore")
    expectNoDifference(value.`inout`, false)
    expectNoDifference(value.`class`, "keyword")
  }

  @Test func optionalAndRequiredChecksUseOriginalKeys() throws {
    let value = try PropertyNamingFixture.schema.parseAndValidate(
      instance: #"""
        {"$id":"identifier","id":42,"a_b":"original","":7,"inout":true,"class":"keyword"}
        """#)
    expectNoDifference(value.a_b_2, nil)
    expectNoDifference(value.property_2, nil)
    #expect(throws: (any Error).self) {
      try PropertyNamingFixture.schema.parseAndValidate(
        instance: #"""
          {"id_2":"identifier","id":42,"a_b":"original","":7,"inout":true,"class":"keyword"}
          """#)
    }
    #expect(throws: (any Error).self) {
      try PropertyNamingFixture.schema.parseAndValidate(
        instance: #"""
          {"$id":"identifier","id":42,"a_b":"original","property":7,"inout":true,"class":"keyword"}
          """#)
    }
  }

  @Test func unicodePunctuationAndNumericKeysCompile() throws {
    @Schema(
      #"""
      {"type":"object","properties":{
        "日本語":{"type":"string"},
        "-":{"type":"integer"},
        "1name":{"type":"boolean"},
        "`class`":{"type":"string"}
      },"required":["日本語","-","1name","`class`"]}
      """#)
    enum ArbitraryKeys {}

    let value = try ArbitraryKeys.schema.parseAndValidate(
      instance: #"{"日本語":"value","-":1,"1name":true,"`class`":"escaped"}"#)
    expectNoDifference(value.property, "value")
    expectNoDifference(value.property_2, 1)
    expectNoDifference(value._1name, true)
    expectNoDifference(value.`class`, "escaped")
  }

  @Test func invalidIdentifierSingletonRemainsUnwrapped() throws {
    @Schema(#"{"type":"object","properties":{"":{"type":"integer"}},"required":[""]}"#)
    enum EmptyKey {}

    let value: Int = try EmptyKey.schema.parseAndValidate(instance: #"{"":42}"#)
    expectNoDifference(value, 42)
  }
}
