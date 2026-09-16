import GeneratedModels
import JSONSchema
import JSONSchemaBuilder

func verifyParserFactories() throws {
  func input(_ level: Int, invalid: Bool = false) throws -> JSONValue {
    if level == 0 {
      return try JSONValue.parse(
        """
        {"id":"leaf","choice":\(invalid ? "true" : "2.5"),"tag":null,
         "future_decimal":1.0000000000000000001,"future_huge":1e400}
        """)
    }
    var object = JSONValue.object([:]).object!
    for index in 0..<4 { object["field\(index)"] = try input(level - 1, invalid: invalid) }
    object["future_null"] = .null
    return .object(object)
  }
  let json = try input(3)
  let model = try FactorySchemas.schemaRoot.parseAndValidate(json)
  let sharedLeaf: FactorySchemas.Leaf = model.field0!.field0!.field0!
  try check(sharedLeaf.id == "leaf", "Parser factoring changed shared reference identity.")
  let encoded = try FactorySchemas.encodeRoot(model)
  try check(encoded == json, "Complex factored parser changed model encoding.")
  let leaf = encoded.object!["field0"]!.object!["field0"]!.object!["field0"]!
  try check(
    leaf.object!["future_decimal"]!.numberLiteral!.rawValue == "1.0000000000000000001",
    "Factored parser rounded an unknown decimal.")
  try check(
    leaf.object!["future_huge"]!.numberLiteral!.rawValue == "1e400",
    "Factored parser rounded an unknown large number.")
  _ = try LegacyFactorySchemas.schema.parseAndValidate(json)
  try check(
    try FactorySchemas.schemaRoot.schemaValue.value.serialized().utf8.elementsEqual(
      LegacyFactorySchemas.schema.schemaValue.value.serialized().utf8),
    "Factoring changed the complete original validation definition.")
  let invalid = try input(3, invalid: true)
  try check(
    !FactorySchemas.schemaRoot.definition().validate(invalid).isValid,
    "Factoring weakened nested union validation.")
  do {
    _ = try FactorySchemas.schemaRoot.parseAndValidate(invalid)
    throw SharedFailure(message: "Factored parser accepted an invalid nested union.")
  } catch is SharedFailure {
    throw SharedFailure(message: "Factored parser accepted an invalid nested union.")
  } catch {
    try check(
      !LegacyFactorySchemas.schema.definition().validate(invalid).isValid,
      "Factored and unfactored validation disagree.")
  }
  print("Complex parser factories preserve validation, nominal identity, and exact unknown values.")
}
