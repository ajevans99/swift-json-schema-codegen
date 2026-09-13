import Foundation
import GeneratedModels
import JSONSchema
import JSONSchemaBuilder

private func scalars(_ value: String) -> [UInt32] {
  value.unicodeScalars.map(\.value)
}

private func quoted(_ value: String) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func roundTrip<E: RawRepresentable & Hashable & Sendable>(
  _ type: E.Type, values: [String]
) throws where E.RawValue == String {
  var cases: Set<E> = []
  for raw in values {
    guard let value = E(rawValue: raw) else {
      throw ConsumerFailure(description: "Public raw initializer rejected scalars \(scalars(raw)).")
    }
    try check(scalars(value.rawValue) == scalars(raw), "Raw value changed Unicode scalars.")
    try check(E(rawValue: value.rawValue) == value, "Public enum raw roundtrip changed its case.")
    requireSendable(value)
    cases.insert(value)
  }
  try check(
    cases.count == Set(values.map(scalars)).count,
    "Hashable merged distinct scalar sequences or failed to merge identical duplicates.")
}

private func parity<M: JSONSchemaComponent, T: JSONSchemaComponent>(
  _ models: M, _ tuples: T, valid: [String], invalid: [String]
) throws {
  try check(models.schemaValue == tuples.schemaValue, "Enum validation schemas differ.")
  for source in valid {
    let value = try JSONValue.parse(source)
    try check(models.definition().validate(value).isValid, "Named validator rejected \(source).")
    try check(tuples.definition().validate(value).isValid, "Tuple validator rejected \(source).")
    _ = try models.parseAndValidate(value)
    _ = try tuples.parseAndValidate(value)
  }
  for source in invalid {
    try reject(models, source)
    try reject(tuples, source)
  }
}

func checkStringEnums() throws {
  let statuses = ["draft", "in-progress", "done"]
  try roundTrip(StatusSchema.Value.self, values: statuses)
  let status: StatusSchema.Value = .inProgress
  try check(scalars(status.rawValue) == scalars("in-progress"), "Case normalization lost raw text.")
  try check(StatusSchema.Value(rawValue: "missing") == nil, "Unknown raw enum value was accepted.")
  try check(
    Set<StatusSchema.Value>([.draft, .inProgress, .done]).count == 3,
    "Root enum cases are not publicly usable.")
  for raw in statuses {
    let source = try quoted(raw)
    let named: StatusSchema.Value = try StatusSchema.schema.parseAndValidate(instance: source)
    let tuple: String = try StatusSchemaTuples.schema.parseAndValidate(instance: source)
    try check(scalars(named.rawValue) == scalars(tuple), "Root tuple/enum output changed raw text.")
    let inferred: InferredEnumSchema.Value = try InferredEnumSchema.schema.parseAndValidate(
      instance: source)
    let legacyInferred: JSONValue = try InferredEnumSchemaTuples.schema.parseAndValidate(
      instance: source)
    guard case .string(let legacyString) = legacyInferred else {
      throw ConsumerFailure(description: "Inferred tuple enum is no longer a JSONValue.")
    }
    try check(
      scalars(inferred.rawValue) == scalars(legacyString), "Inferred enum changed raw text.")
  }
  let validStatuses = try statuses.map(quoted)
  let invalidStatuses = [#""missing""#, #""DRAFT""#, "null", "1", "true", "{}", "[]"]
  try parity(
    StatusSchema.schema, StatusSchemaTuples.schema,
    valid: validStatuses, invalid: invalidStatuses)
  try parity(
    InferredEnumSchema.schema, InferredEnumSchemaTuples.schema,
    valid: validStatuses, invalid: invalidStatuses)

  let nullable: NullableEnumSchema.Value = NullableEnumSchema.StringValue.inProgress
  let absent: NullableEnumSchema.Value = nil
  try check(nullable == .inProgress && absent == nil, "Nullable root is not an enum Optional.")
  let parsedNull: NullableEnumSchema.Value = try NullableEnumSchema.schema.parseAndValidate(
    instance: "null")
  let tupleNull: String? = try NullableEnumSchemaTuples.schema.parseAndValidate(instance: "null")
  try check(parsedNull == nil && tupleNull == nil, "Nullable root changed null.")
  let inferredNullable: InferredNullableEnumSchema.Value = .draft
  let inferredNull: InferredNullableEnumSchema.Value =
    try InferredNullableEnumSchema.schema.parseAndValidate(instance: "null")
  let inferredTupleNull: JSONValue =
    try InferredNullableEnumSchemaTuples.schema.parseAndValidate(instance: "null")
  try check(
    inferredNullable == .draft && inferredNull == nil && inferredTupleNull == .null,
    "Inferred nullable enum changed its legacy or named representation.")
  try roundTrip(NullableEnumSchema.StringValue.self, values: statuses)
  try roundTrip(InferredNullableEnumSchema.StringValue.self, values: ["draft", "done"])
  try parity(
    NullableEnumSchema.schema, NullableEnumSchemaTuples.schema,
    valid: validStatuses + ["null"], invalid: [#""missing""#, "false", "1"])
  try parity(
    InferredNullableEnumSchema.schema, InferredNullableEnumSchemaTuples.schema,
    valid: [#""draft""#, #""done""#, "null"], invalid: [#""missing""#, "false", "1"])

  let unicode = ["\u{E9}", "e\u{301}", "\u{C5}"]
  try roundTrip(UnicodeEnumSchema.Value.self, values: unicode)
  try check(
    UnicodeEnumSchema.Value(rawValue: unicode[0]) != UnicodeEnumSchema.Value(rawValue: unicode[1]),
    "Canonical equivalents merged into a single generated case.")
  try check(
    UnicodeEnumSchema.Value(rawValue: "A\u{30A}") == nil,
    "Raw initializer accepted an absent normalization variant.")
  for raw in unicode {
    let source = try quoted(raw)
    let named = try UnicodeEnumSchema.schema.parseAndValidate(instance: source)
    let tuple: String = try UnicodeEnumSchemaTuples.schema.parseAndValidate(instance: source)
    try check(
      scalars(named.rawValue) == scalars(raw) && scalars(tuple) == scalars(raw),
      "Unicode enum parser normalized the source spelling.")
  }
  try parity(
    UnicodeEnumSchema.schema, UnicodeEnumSchemaTuples.schema,
    valid: try unicode.map(quoted),
    invalid: [#""unknown""#, #""A\u030A""#, "null", "42"])

  let awkward = [
    "repeat", "repeat", "", "---", "1st", "class", "self", "Self", "init", "deinit",
    "Type", "Protocol", "rawValue", "RawValue", "hash", "hashValue", "a-b", "a_b",
    "a b", "a\"b", "line\nbreak", "slash\\path", "💫",
  ]
  try roundTrip(AwkwardEnumSchema.Value.self, values: awkward)
  let overridden: AwkwardEnumSchema.Value = .repeated
  let keyword: AwkwardEnumSchema.Value = .class
  let initializer: AwkwardEnumSchema.Value = .`init`
  try check(
    scalars(overridden.rawValue) == scalars("repeat")
      && scalars(keyword.rawValue) == scalars("class")
      && scalars(initializer.rawValue) == scalars("init"),
    "Duplicate-index overrides or keyword cases lost their literal values.")
  for raw in awkward {
    let source = try quoted(raw)
    let named = try AwkwardEnumSchema.schema.parseAndValidate(instance: source)
    let tuple: String = try AwkwardEnumSchemaTuples.schema.parseAndValidate(instance: source)
    try check(
      scalars(named.rawValue) == scalars(raw) && scalars(tuple) == scalars(raw),
      "Awkward enum literal did not roundtrip.")
  }
  try parity(
    AwkwardEnumSchema.schema, AwkwardEnumSchemaTuples.schema,
    valid: try awkward.map(quoted), invalid: [#""missing""#, "null", "17"])

  let containerSource =
    #"{"status":"in-progress","reused":"draft","distinct":"done","nullable":null,"states":["draft","done"],"byName":{"first":"in-progress"},"extra":"done"}"#
  let container = try EnumContainerSchema.schema.parseAndValidate(instance: containerSource)
  let tupleContainer = try EnumContainerSchemaTuples.schema.parseAndValidate(
    instance: containerSource)
  let reused: EnumContainerSchema.State = container.reused
  let distinct: EnumContainerSchema.Twin = container.distinct
  let nullableField: EnumContainerSchema.NullableState? = container.nullable
  let optionalNullable: EnumContainerSchema.NullableState?? = container.optionalNullable
  try check(
    reused == .draft && distinct == .done && nullableField == nil && optionalNullable == nil,
    "Reference enum field types or absent/null state changed.")
  try check(
    ObjectIdentifier(EnumContainerSchema.State.self)
      != ObjectIdentifier(EnumContainerSchema.Twin.self),
    "Distinct equal enum definitions were structurally merged.")
  try check(
    container.status == .inProgress && container.optionalState == nil
      && container.states == [.draft, .done] && container.byName["first"] == .inProgress
      && container.additionalProperties["extra"] == .done,
    "Enum array/dictionary/additional-properties references changed.")
  try check(
    scalars(tupleContainer.0.status) == scalars(container.status.rawValue)
      && tupleContainer.1["extra"].map(scalars)
        == container.additionalProperties["extra"].map {
          scalars($0.rawValue)
        },
    "Legacy tuple enum containers stopped exposing String values.")
  let explicitNullSource = containerSource.dropLast() + #","optionalNullable":null}"#
  let explicitNull = try EnumContainerSchema.schema.parseAndValidate(
    instance: String(explicitNullSource))
  guard case .some(.none) = explicitNull.optionalNullable else {
    throw ConsumerFailure(description: "Enum T?? did not preserve explicit null.")
  }
  let presentSource = containerSource.dropLast() + #","optionalNullable":"draft"}"#
  let present = try EnumContainerSchema.schema.parseAndValidate(instance: String(presentSource))
  guard case .some(.some(.draft)) = present.optionalNullable else {
    throw ConsumerFailure(description: "Enum T?? did not preserve the present string case.")
  }
  let constructed = EnumContainerSchema.Value(
    status: .draft, reused: .done, distinct: .inProgress, nullable: nil,
    states: [.draft], byName: ["first": .done], additionalProperties: ["extra": .inProgress])
  requireSendable(constructed)
  try check(
    constructed.optionalState == nil && constructed.optionalNullable == nil,
    "Optional enum constructor fields lost their defaults.")
  try parity(
    EnumContainerSchema.schema, EnumContainerSchemaTuples.schema,
    valid: [containerSource, String(explicitNullSource), String(presentSource)],
    invalid: [
      containerSource.replacingOccurrences(
        of: #""status":"in-progress""#, with: #""status":"missing""#),
      containerSource.replacingOccurrences(of: #""nullable":null,"#, with: ""),
      containerSource.replacingOccurrences(of: #""extra":"done""#, with: #""extra":"missing""#),
      containerSource.replacingOccurrences(of: #""first":"in-progress""#, with: #""first":3"#),
      containerSource.replacingOccurrences(of: #"["draft","done"]"#, with: #"["draft","missing"]"#),
      String(containerSource.dropLast()) + #","optionalState":null}"#,
    ])

  let firstBound: EnumCompositionsSchema.Intersection = .draft
  try check(
    scalars(firstBound.rawValue) == scalars("draft"),
    "allOf must expose its first enum bound, not satisfiability-minimized cases.")
  let composition = try EnumCompositionsSchema.schema.parseAndValidate(
    instance:
      #"{"intersection":"done","refined":"done","constant":"draft","patterned":"done","either":"shared","exclusive":"right-only"}"#
  )
  let constant: EnumCompositionsSchema.State? = composition.constant
  let patterned: EnumCompositionsSchema.State? = composition.patterned
  let refined: EnumCompositionsSchema.Refined? = composition.refined
  try check(
    composition.intersection == .finished && refined == .completed
      && constant == .draft && patterned == .done,
    "Enum reference specialization or validation-only base reuse changed.")
  try check(
    ObjectIdentifier(EnumCompositionsSchema.Refined.self)
      != ObjectIdentifier(EnumCompositionsSchema.State.self),
    "Enum-valued reference sibling did not specialize the base enum.")
  guard case .some(.left(let left)) = composition.either,
    case .some(.right(let right)) = composition.exclusive
  else {
    throw ConsumerFailure(description: "String enum union payloads lost semantic branch selection.")
  }
  let leftPayload: EnumCompositionsSchema.EitherLeft = left
  let rightPayload: EnumCompositionsSchema.ExclusiveRight = right
  try check(
    leftPayload == .shared && rightPayload == .rightOnly, "Union enum payload cases changed.")
  requireSendable(EnumCompositionsSchema.Either.right(.rightOnly))
  requireSendable(EnumCompositionsSchema.Exclusive.left(.leftOnly))
  try parity(
    EnumCompositionsSchema.schema, EnumCompositionsSchemaTuples.schema,
    valid: [
      "{}", #"{"intersection":"done"}"#, #"{"refined":"done"}"#, #"{"constant":"draft"}"#,
      #"{"patterned":"done"}"#, #"{"either":"shared"}"#, #"{"either":"right-only"}"#,
      #"{"exclusive":"left-only"}"#, #"{"exclusive":"right-only"}"#,
    ],
    invalid: [
      #"{"intersection":"draft"}"#, #"{"intersection":"in-progress"}"#,
      #"{"refined":"draft"}"#, #"{"constant":"done"}"#, #"{"patterned":"in-progress"}"#,
      #"{"exclusive":"shared"}"#, #"{"either":"missing"}"#, #"{"exclusive":"missing"}"#,
    ])

  requireSendable(
    LegacyEnumSchema.Value(
      empty: "uninhabited", nullOnly: .some(nil), mixed: "draft", untypedMixed: .integer(1),
      constant: "draft", unconstrained: "anything"))
  let legacy = try LegacyEnumSchema.schema.parseAndValidate(
    instance:
      #"{"nullOnly":null,"mixed":"draft","untypedMixed":1,"constant":"draft","unconstrained":"anything"}"#
  )
  let legacyString: String? = legacy.mixed
  let legacyMixed: JSONValue? = legacy.untypedMixed
  try check(
    legacyString == "draft" && legacyMixed == .integer(1),
    "Excluded enum shapes must retain legacy scalar representations.")
  try parity(
    LegacyEnumSchema.schema, LegacyEnumSchemaTuples.schema,
    valid: ["{}", #"{"nullOnly":null,"mixed":"draft","untypedMixed":1,"constant":"draft"}"#],
    invalid: [
      #"{"empty":""}"#, #"{"nullOnly":"draft"}"#, #"{"mixed":1}"#,
      #"{"untypedMixed":false}"#, #"{"constant":"done"}"#,
    ])

  try parity(
    OpenAPIOptionsSchema.schema, OpenAPIOptionsSchemaTuples.schema,
    valid: [#"{"payload":{"number":11},"result":12,"status":"in-progress"}"#],
    invalid: [
      #"{"payload":{"number":11},"result":12,"status":"missing"}"#,
      #"{"payload":{"number":11},"result":12}"#,
    ])
}
