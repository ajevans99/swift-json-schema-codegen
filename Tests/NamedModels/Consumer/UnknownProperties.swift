import GeneratedModels
import JSONSchema
import JSONSchemaBuilder

func verifyUnknownProperties() throws {
  let leaf = try JSONValue.parse(
    """
    {"id":"leaf","unmodeledProperties":"declared",
     "future_integer":123456789012345678901234567890,
     "future_decimal":1.0000000000000000001,"future_null":null,
     "meta_exact":1e400,"meta_null":null}
    """)
  let input = JSONValue.object([
    "id": "root", "leaf": leaf, "leaves": .array([leaf]),
    "future": .object(["tiny": try JSONValue.parse("1e-400"), "null": .null]),
  ])
  let preserved = try PreservedUnknownSchemas.schemaNested.parseAndValidate(input)
  let shared: PreservedUnknownSchemas.Leaf = preserved.leaves[0]
  try check(shared.id == preserved.leaf.id, "Preservation broke shared nominal identity.")
  try check(
    preserved.leaf.unmodeledProperties == "declared",
    "Unmodeled storage collided with a schema-declared property name.")
  let output = try PreservedUnknownSchemas.encodeNested(preserved)
  try check(output == input, "Unknown nested or referenced properties were lost.")
  for key in ["future_integer", "future_decimal", "meta_exact"] {
    try check(
      output.object?["leaf"]?.object?[key]?.numberLiteral?.rawValue
        == leaf.object?[key]?.numberLiteral?.rawValue,
      "Unknown property number tokens changed.")
  }
  let legacy = try DefaultUnknownSchemas.schemaNested.parseAndValidate(input)
  let legacyJSON = try DefaultUnknownSchemas.encodeNested(legacy)
  try check(legacyJSON.object?["future"] == nil, "Default projection unexpectedly changed.")
  try check(
    legacyJSON.object?["leaf"]?.object?["future_null"] == nil,
    "Default nested projection unexpectedly changed.")

  let booleanInput: JSONValue = .object(["id": "id", "future": leaf])
  let booleanValue = try PreservedUnknownSchemas.schemaBooleanExtras.parseAndValidate(booleanInput)
  try check(
    try PreservedUnknownSchemas.encodeBooleanExtras(booleanValue) == booleanInput,
    "Explicit boolean additionalProperties did not preserve unknown keys.")
  let typed = try JSONValue.parse(
    #"{"id":"id","ghost":3,"extra":7,"pattern_exact":1e400,"pattern_null":null}"#)
  let typedModel = try PreservedUnknownSchemas.schemaPatternTyped.parseAndValidate(typed)
  try check(typedModel.additionalProperties == ["extra": 7], "Typed extras changed coverage.")
  try check(
    typedModel.unmodeledProperties["pattern_null"] == .null,
    "Pattern-matched unmodeled keys were lost.")
  try check(
    try PreservedUnknownSchemas.encodePatternTyped(typedModel) == typed,
    "Typed extras, required-only fields, and pattern fields did not round trip.")
  let typedOnly = try JSONValue.parse(#"{"extra":2,"raw_value":1e-400,"raw_null":null}"#)
  let typedOnlyModel = try PreservedUnknownSchemas.schemaTypedOnly.parseAndValidate(typedOnly)
  try check(
    try PreservedUnknownSchemas.encodeTypedOnly(typedOnlyModel) == typedOnly,
    "Property-free typed dictionaries lost pattern-matched keys.")

  let composed = try JSONValue.parse(#"{"a":"a","b":2,"future":"text","future_null":null}"#)
  let composedModel = try PreservedUnknownSchemas.schemaComposed.parseAndValidate(composed)
  try check(
    try PreservedUnknownSchemas.encodeComposed(composedModel) == composed,
    "Composition changed unknown-property coverage.")
  let union = try PreservedUnknownSchemas.schemaUnion.parseAndValidate(leaf)
  try check(
    try PreservedUnknownSchemas.encodeUnion(union) == leaf,
    "Semantic union projection lost unmodeled object properties.")
  for (preservedSchema, defaultSchema) in [
    (
      PreservedUnknownSchemas.schemaNested.schemaValue,
      DefaultUnknownSchemas.schemaNested.schemaValue
    ),
    (
      PreservedUnknownSchemas.schemaPatternTyped.schemaValue,
      DefaultUnknownSchemas.schemaPatternTyped.schemaValue
    ),
    (
      PreservedUnknownSchemas.schemaComposed.schemaValue,
      DefaultUnknownSchemas.schemaComposed.schemaValue
    ),
    (
      PreservedUnknownSchemas.schemaStrict.schemaValue,
      DefaultUnknownSchemas.schemaStrict.schemaValue
    ),
  ] {
    try check(
      try preservedSchema.value.serialized().utf8.elementsEqual(
        defaultSchema.value.serialized().utf8),
      "Preserving unknown properties changed the original validation definition.")
  }
  for invalid in [
    #"{"id":"id","unexpected":null}"#,
    #"{"id":"id","meta_invalid":"not a number"}"#,
  ] {
    do {
      _ = try PreservedUnknownSchemas.schemaStrict.parseAndValidate(instance: invalid)
      throw SharedFailure(message: "Forbidden extra properties unexpectedly parsed.")
    } catch is SharedFailure {
      throw SharedFailure(message: "Forbidden extra properties unexpectedly parsed.")
    } catch {
      try check(
        !PreservedUnknownSchemas.schemaStrict.definition().validate(try JSONValue.parse(invalid))
          .isValid,
        "Original reference/unevaluatedProperties restriction was weakened.")
    }
  }
  try check(
    !PreservedUnknownSchemas.schemaForbidden.definition()
      .validate(.object(["id": "id", "future": .null])).isValid,
    "Explicit additionalProperties:false was weakened.")
  try check(
    !PreservedUnknownSchemas.schemaComposed.definition()
      .validate(.object(["a": "a", "b": 2, "future": true])).isValid,
    "Composition's unevaluatedProperties schema was weakened.")
  try rejectsEncoding {
    try PreservedUnknownSchemas.encodeLeaf(
      .init(id: "id", unmodeledProperties_2: ["id": "collision"]))
  }
  try rejectsEncoding {
    try PreservedUnknownSchemas.encodePatternTyped(
      .init(
        id: "id", ghost: 3, additionalProperties: ["extra": 1],
        unmodeledProperties: ["extra": 2]))
  }
  print("Opt-in unknown-property preservation, validation scope, and collision checks passed.")
}
