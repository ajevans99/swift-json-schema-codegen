import GeneratedModels
import JSONSchema
import JSONSchemaBuilder

func verifyUnionReferences() throws {
  let direct = try JSONValue.parse(
    """
    {"type":"direct","future":{"decimal":1.0000000000000000001,"huge":1e400,"null":null}}
    """)
  let first = try UnionReferenceSchemas.schemaFirst.parseAndValidate(direct)
  let second: UnionReferenceSchemas.Second = first
  let plain: UnionReferenceSchemas.Plain = second
  guard case .direct(let payload) = plain else {
    throw SharedFailure(message: "A referenced union selected the wrong branch.")
  }
  let canonical: UnionReferenceSchemas.Direct = payload
  let reconstructed: UnionReferenceSchemas.First = .direct(canonical)
  try check(
    try UnionReferenceSchemas.encodeFirst(reconstructed) == direct,
    "Annotated union payloads lost canonical identity or unknown values.")
  try check(
    try UnionReferenceSchemas.encodeSecond(second) == direct,
    "Repeated union references changed encoding.")

  let program = try JSONValue.parse(#"{"type":"program","name":"runner","future":null}"#)
  let caller = try UnionReferenceSchemas.schemaSecond.parseAndValidate(program)
  guard case .program(let programPayload) = caller else {
    throw SharedFailure(message: "The other referenced union branch was not selected.")
  }
  let canonicalProgram: UnionReferenceSchemas.Program = programPayload
  try check(
    try UnionReferenceSchemas.encodePlain(.program(canonicalProgram)) == program,
    "The other canonical union payload changed encoding.")

  let nullable = try UnionReferenceSchemas.schemaNullableFirst.parseAndValidate(direct)
  let otherNullable: UnionReferenceSchemas.NullableSecond = nullable
  let unwrapped: UnionReferenceSchemas.First = otherNullable!
  try check(
    try UnionReferenceSchemas.encodePlain(unwrapped) == direct,
    "Nullable annotated references specialized the union payload.")
  let null = try UnionReferenceSchemas.schemaNullableSecond.parseAndValidate(.null)
  try check(null == nil, "Nullable union references lost explicit null.")
  try check(
    try UnionReferenceSchemas.encodeNullableFirst(null) == .null,
    "Nullable union references encoded null incorrectly.")

  let specialized = try JSONValue.parse(#"{"type":"direct","extra":2,"future":1e-400}"#)
  let typed = try UnionReferenceSchemas.schemaSpecializedFirst.parseAndValidate(specialized)
  let sameSpecialization: UnionReferenceSchemas.SpecializedSecond = typed
  try check(
    try UnionReferenceSchemas.encodeSpecializedSecond(sameSpecialization) == specialized,
    "Shape-changing union refinements lost typed fields or reference sharing.")
  try rejectsUnionParsing(UnionReferenceSchemas.schemaSpecializedFirst, direct)
  try rejectsUnionParsing(
    UnionReferenceSchemas.schemaSpecializedSecond, .object(["type": "direct", "extra": 0]))
  try rejectsUnionParsing(
    UnionReferenceSchemas.schemaSpecializedFirst, .object(["type": "direct", "extra": "wrong"]))
  try rejectsUnionParsing(UnionReferenceSchemas.schemaFirst, .object([:]))
  try rejectsUnionParsing(UnionReferenceSchemas.schemaFirst, .object(["type": "program"]))
  try rejectsUnionParsing(UnionReferenceSchemas.schemaStrict, direct)
  _ = try UnionReferenceSchemas.schemaStrict.parseAndValidate(.object(["type": "direct"]))
  try rejectsUnionParsing(UnionReferenceSchemas.schemaAmbiguousRoot, .object(["type": "direct"]))

  let legacy = LegacyUnionReferenceSchemas.schema
  _ = try legacy.parseAndValidate(
    .object([
      "first": direct, "second": program, "nullableFirst": .null, "specializedFirst": specialized,
    ]))
  let definitions = legacy.schemaValue.value.object!["properties"]!.object!
  for (name, definition) in [
    ("first", UnionReferenceSchemas.schemaFirst.schemaValue),
    ("second", UnionReferenceSchemas.schemaSecond.schemaValue),
    ("plain", UnionReferenceSchemas.schemaPlain.schemaValue),
    ("nullableFirst", UnionReferenceSchemas.schemaNullableFirst.schemaValue),
    ("nullableSecond", UnionReferenceSchemas.schemaNullableSecond.schemaValue),
    ("specializedFirst", UnionReferenceSchemas.schemaSpecializedFirst.schemaValue),
    ("specializedSecond", UnionReferenceSchemas.schemaSpecializedSecond.schemaValue),
    ("strict", UnionReferenceSchemas.schemaStrict.schemaValue),
    ("ambiguous", UnionReferenceSchemas.schemaAmbiguousRoot.schemaValue),
  ] {
    try check(
      try definition.value.serialized().utf8.elementsEqual(definitions[name]!.serialized().utf8),
      "A shared union reference changed the complete validation definition at \(name).")
  }
  let annotations = try UnionReferenceSchemas.schemaFirst.schemaValue.value.serialized()
  for original in [
    "The original caller description.", "First use site.",
    #""default":{"type":"direct"}"#, #""default":{"type":"program","name":"example"}"#,
    #""discriminator":{"propertyName":"type"}"#,
  ] {
    try check(
      annotations.contains(original), "Union projection lost original metadata: \(original)")
  }
  print(
    "Union references preserve canonical payloads, refinements, nullable wrappers, and validation.")
}

private func rejectsUnionParsing(_ schema: some JSONSchemaComponent, _ value: JSONValue) throws {
  try check(
    !schema.definition().validate(value).isValid,
    "Union refinement, required field, or oneOf validity was weakened.")
  do {
    _ = try schema.parseAndValidate(value)
  } catch ParseAndValidateIssue.validationFailed(_),
    ParseAndValidateIssue.parsingAndValidationFailed(_, _)
  {
    return
  }
  throw SharedFailure(message: "Invalid union input unexpectedly parsed.")
}
