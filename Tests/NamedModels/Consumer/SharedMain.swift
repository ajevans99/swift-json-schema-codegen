import Foundation
import GeneratedModels
import JSONSchema
import JSONSchemaBuilder

struct SharedFailure: Error {
  let message: String
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  guard try condition() else { throw SharedFailure(message: message) }
}

func rejectsEncoding(_ encode: () throws -> JSONValue) throws {
  do {
    _ = try encode()
    throw SharedFailure(message: "Invalid value unexpectedly encoded.")
  } catch is SharedFailure {
    throw SharedFailure(message: "Invalid value unexpectedly encoded.")
  } catch {
    try check(String(describing: error).contains("#/"), "Encoding error lost its source pointer.")
  }
}

let constructed: SharedSchemas.Retrieve = .init(
  id: 7, wire_name: "wire", nickname: nil, additionalProperties_2: ["extra": 9])
let request: SharedSchemas.Create = constructed
let list: SharedSchemas.List = [request]
let retrievedFromList: SharedSchemas.Retrieve = list[0]
let encoded = try SharedSchemas.encoderCreate(retrievedFromList)
try check(encoded.object?["wire-name"] == .string("wire"), "JSON field names were sanitized.")
try check(encoded.object?["nickname"] == .null, "Required nullable value was omitted.")
try check(encoded.object?["contact"] == nil, "Absent nullable property became explicit null.")
try check(encoded.object?["extra"] == .integer(9), "Additional properties were not flattened.")
let parsed: SharedSchemas.Retrieve = try SharedSchemas.schemaRetrieve.parseAndValidate(encoded)
let parsedList: SharedSchemas.List = try SharedSchemas.schemaList.parseAndValidate(
  .array([encoded]))
let sameModel: SharedSchemas.Create = parsedList[0]
try check(parsed.id == sameModel.id, "List/retrieve/create models are not interchangeable.")
let parsedDictionary = try SharedSchemas.schemaDictionaryRoot.parseAndValidate(
  .object(["a": encoded]))
let dictionaryValue: SharedSchemas.Retrieve = parsedDictionary["a"]!
try check(dictionaryValue.id == request.id, "Dictionary items do not share the model.")
let dictionaryJSON = try SharedSchemas.encodeDictionaryRoot(["a": request])
try check(dictionaryJSON.object?["a"] == encoded, "Dictionary encoding changed values.")

let nullJSON = try JSONValue.parse(
  #"{"id":1,"wire-name":"hello","nickname":"nick","contact":null}"#)
let nullModel = try SharedSchemas.schemaRetrieve.parseAndValidate(nullJSON)
guard case .some(.none) = nullModel.contact else {
  throw SharedFailure(message: "Explicit null did not survive parsing.")
}
try check(
  try SharedSchemas.encodeRetrieve(nullModel) == nullJSON,
  "Optional nullable value did not preserve explicit null.")
let present = try SharedSchemas.schemaRetrieve.parseAndValidate(
  instance: #"{"id":1,"wire-name":"hi","nickname":null,"contact":"contact"}"#)
try check(
  try SharedSchemas.encodeRetrieve(present).object?["contact"] == .string("contact"),
  "Present nullable value was lost.")

for raw in ["é", "e\u{301}"] {
  let json = JSONValue.object([
    "id": .integer(1), "wire-name": .string("wire"), "nickname": .null, "status": .string(raw),
  ])
  let model = try SharedSchemas.schemaRetrieve.parseAndValidate(json)
  let encodedStatus = try SharedSchemas.encodeRetrieve(model).object?["status"]?.string
  try check(
    encodedStatus?.unicodeScalars.elementsEqual(raw.unicodeScalars) == true,
    "String enum encoding normalized Unicode scalar identity.")
}
let exact = try JSONValue.parse(
  #"{"huge":1e400,"tiny":1e-400,"decimal":0.123456789012345678901}"#)
let exactOutput = try SharedSchemas.encodeAnything(exact)
for key in ["huge", "tiny", "decimal"] {
  try check(
    exactOutput.object?[key]?.numberLiteral?.rawValue
      == exact.object?[key]?.numberLiteral?.rawValue,
    "JSONValue encoding rounded an exact number literal.")
}
let carryingExact: SharedSchemas.Create = .init(
  id: 1, wire_name: "exact", nickname: nil, payload: exact, additionalProperties_2: [:])
try check(
  try SharedSchemas.encodeCreate(carryingExact).object?["payload"] == exact,
  "Modeled JSONValue payload did not preserve exact numbers.")
try rejectsEncoding { try SharedSchemas.encodeNumberRoot(.infinity) }
try rejectsEncoding { try SharedSchemas.encodeNumberRoot(.nan) }
try check(try SharedSchemas.encodeNumberRoot(1.25) == .number(1.25), "Finite number changed.")
try check(
  try SharedSchemas.encodePrefixRoot([.integer(1), exact]) == .array([.integer(1), exact]),
  "Prefix array discarded unprojected JSON values.")
try check(
  try SharedSchemas.encodeNullableRoot(nil) == .null, "Nullable object root did not encode.")
try check(
  try SharedSchemas.encodeNullArray([(), ()]) == .array([.null, .null]),
  "Null array items did not encode.")
try check(
  try SharedSchemas.encodeNullDictionary(["a": ()]) == .object(["a": .null]),
  "Null dictionary values did not encode.")
try check(
  try SharedSchemas.encodeNullFields(.init(requiredNull: (), optionalNull: .some(())))
    == .object(["requiredNull": .null, "optionalNull": .null]),
  "Null-valued fields did not encode.")
try check(
  try SharedSchemas.encodeNullFields(.init(requiredNull: ())) == .object(["requiredNull": .null]),
  "Absent null-valued field did not remain absent.")
try check(
  try SharedSchemas.encodeEmptyRoot(.init()) == .object([:]), "Empty object did not encode.")

try rejectsEncoding {
  try SharedSchemas.encodeCreate(
    .init(id: 1, wire_name: "bad", nickname: nil, additionalProperties_2: ["id": 2]))
}
try rejectsEncoding {
  try SharedSchemas.encodeCreate(
    .init(id: 1, wire_name: "bad", nickname: nil, additionalProperties_2: ["contact": 2]))
}
let requiredOnly = SharedSchemas.Only(token: .integer(4), additionalProperties: ["other": 8])
try check(
  try SharedSchemas.encodeOnly(requiredOnly)
    == .object(["token": .integer(4), "other": .integer(8)]),
  "Required-only field was discarded.")
try rejectsEncoding {
  try SharedSchemas.encodeOnly(.init(token: .integer(4), additionalProperties: ["token": 4]))
}

for json in [
  #"{"kind":"ready","message":"ok"}"#,
  #"{"kind":"pending","count":2}"#,
] {
  let value = try JSONValue.parse(json)
  let parsed = try SharedSchemas.schemaResponse.parseAndValidate(value)
  switch parsed {
  case .ready(let payload): try check(payload.message == "ok", "Semantic ready case changed.")
  case .pending(let payload): try check(payload.count == 2, "Semantic pending case changed.")
  }
  try check(
    try SharedSchemas.encodeResponse(parsed) == value, "Semantic union encoding changed JSON.")
}
let tree: SharedSchemas.TreeRoot = .init(
  name: "root", children: [.init(name: "leaf", children: [])])
let treeList: SharedSchemas.TreeList = [tree]
let roundtripTrees = try SharedSchemas.schemaTreeList.parseAndValidate(
  SharedSchemas.encodeTreeList(treeList))
try check(roundtripTrees[0].children[0].name == "leaf", "Recursive shared models failed.")
let expressionJSON = try JSONValue.parse(#"{"not":{"not":true}}"#)
let expression = try SharedSchemas.schemaExpressionRoot.parseAndValidate(expressionJSON)
try check(
  try SharedSchemas.encodeExpressionRoot(expression) == expressionJSON,
  "Recursive semantic union encoding failed.")

let baseJSON = try JSONValue.parse(#"{"name":"base","children":[{"name":"leaf","children":[]}]}"#)
let base = try SharedDynamicSchemas.schemaBaseTree.parseAndValidate(baseJSON)
try check(
  try SharedDynamicSchemas.encodeBaseTree(base) == baseJSON,
  "Base dynamic-reference encoding failed.")
let strictJSON = try JSONValue.parse(
  #"{"name":"strict","extra":true,"children":[{"name":"leaf","extra":false,"children":[]}]}"#)
let strict = try SharedDynamicSchemas.schemaStrictTree.parseAndValidate(strictJSON)
try check(strict.extra && !strict.children[0].extra, "Dynamic specialization lost typed fields.")
try check(
  try SharedDynamicSchemas.encodeStrictTree(strict) == strictJSON,
  "Specialized dynamic-reference encoding failed.")
try check(
  SharedUntypedSchemas.schemaRetrieve.schemaValue == LegacyUntypedSchema.schema.schemaValue,
  "Untyped object projection changed the original validation schema.")
try check(
  SharedUntypedSchemas.schemaStrict.schemaValue == LegacyUntypedStrictSchema.schema.schemaValue,
  "Untyped object projection changed reference-sibling annotation scope.")
let untypedObject = JSONValue.object([
  "id": .string("model"), "created": .integer(7), "nickname": .null,
])
let untyped = try SharedUntypedSchemas.schemaRetrieve.parseAndValidate(untypedObject)
guard case .object(let payload) = untyped else {
  throw SharedFailure(message: "Valid untyped object did not receive a typed payload.")
}
let typedPayload: SharedUntypedSchemas.ModelObject = payload
try check(
  typedPayload.id == "model" && typedPayload.created == 7, "Untyped fields lost their types.")
guard case .some(.none) = payload.nickname else {
  throw SharedFailure(message: "Untyped payload lost absence/null distinction.")
}
let constructedUntyped: SharedUntypedSchemas.Retrieve =
  .object(.init(id: "constructed", created: 42))
let constructedUntypedList: SharedUntypedSchemas.List = [constructedUntyped]
let parsedUntypedList = try SharedUntypedSchemas.schemaList.parseAndValidate(
  SharedUntypedSchemas.encodeList(constructedUntypedList))
let sharedUntypedRoot: SharedUntypedSchemas.Retrieve = parsedUntypedList[0]
guard case .object(let constructedPayload) = sharedUntypedRoot else {
  throw SharedFailure(message: "List/retrieve untyped objects did not share a model.")
}
try check(constructedPayload.id == "constructed", "Constructed untyped object did not round-trip.")
try check(
  try SharedUntypedSchemas.encodeRetrieve(untyped) == untypedObject,
  "Untyped object's modeled values changed during encoding.")
_ = try SharedUntypedSchemas.schemaStrict.parseAndValidate(untypedObject)
for invalid in [
  JSONValue.object([:]),
  .object(["id": .integer(1), "created": .integer(7)]),
  .object(["id": .string(""), "created": .integer(7)]),
  .object(["id": .string("model")]),
] {
  guard case .invalid = SharedUntypedSchemas.schemaRetrieve.parse(invalid) else {
    throw SharedFailure(message: "Invalid object escaped through the nonobject fallback.")
  }
  do {
    _ = try SharedUntypedSchemas.schemaRetrieve.parseAndValidate(invalid)
    throw SharedFailure(message: "Invalid object was accepted by parseAndValidate.")
  } catch is ParseAndValidateIssue {}
}
let unevaluated = JSONValue.object([
  "id": .string("model"), "created": .integer(7), "extra": .boolean(true),
])
_ = try SharedUntypedSchemas.schemaRetrieve.parseAndValidate(unevaluated)
do {
  _ = try SharedUntypedSchemas.schemaStrict.parseAndValidate(unevaluated)
  throw SharedFailure(message: "Reference sibling unevaluatedProperties stopped rejecting extras.")
} catch is ParseAndValidateIssue {}
for nonobject in [
  JSONValue.null, .string("allowed"), .boolean(false),
  .array([.object(["anything": .boolean(true)])]), try JSONValue.parse("1e400"),
] {
  let parsed = try SharedUntypedSchemas.schemaRetrieve.parseAndValidate(nonobject)
  guard case .nonObject(let raw) = parsed else {
    throw SharedFailure(message: "Allowed nonobject was not retained as JSONValue.")
  }
  try check(raw == nonobject, "Nonobject wrapper changed the original value.")
  try check(
    try SharedUntypedSchemas.encodeRetrieve(parsed) == nonobject,
    "Nonobject encoding changed the original value.")
  if let literal = nonobject.numberLiteral {
    try check(
      try SharedUntypedSchemas.encodeRetrieve(parsed).numberLiteral?.rawValue == literal.rawValue,
      "Nonobject encoding rounded an exact number literal.")
  }
}
try rejectsEncoding { try SharedUntypedSchemas.encodeRetrieve(.nonObject(untypedObject)) }
try rejectsEncoding { try SharedUntypedSchemas.encodeRetrieve(.nonObject(.object([:]))) }
print(
  "Shared-model cross-module construction, parsing, encoding, identity, and rejection checks passed."
)
