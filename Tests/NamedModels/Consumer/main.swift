import Foundation
import GeneratedModels
import JSONSchema
import JSONSchemaBuilder

struct ConsumerFailure: Error, CustomStringConvertible {
  let description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw ConsumerFailure(description: message) }
}

func requireSendable<T: Sendable>(_ value: T) {}

func reject<C: JSONSchemaComponent>(_ component: C, _ source: String) throws {
  let value = try JSONValue.parse(source)
  try check(!component.definition().validate(value).isValid, "Validator accepted \(source)")
  do {
    _ = try component.parseAndValidate(value)
    throw ConsumerFailure(description: "Parser accepted \(source)")
  } catch let issue as ParseAndValidateIssue {
    switch issue {
    case .validationFailed, .parsingAndValidationFailed:
      return
    case .decodingFailed, .parsingFailed:
      throw ConsumerFailure(description: "Expected validation failure for \(source), got \(issue)")
    }
  }
}

try check(schemasHaveIdenticalValidationValues(), "Named output changed a validation schema.")

let person: PersonSchema.Value = try PersonSchema.schema.parseAndValidate(
  instance: #"{"name":"Ada","address":{"street":"First"},"nickname":null}"#)
let address: PersonSchema.Address = person.address
try check(address.street == "First" && address.postalCode == nil, "Named address fields failed.")
try check(person.nickname == nil && person.contact == nil, "Absent/required-null fields changed.")
let explicitNull = try PersonSchema.schema.parseAndValidate(
  instance: #"{"name":"Ada","address":{"street":"First"},"nickname":"A","contact":null}"#)
guard case .some(.none) = explicitNull.contact else {
  throw ConsumerFailure(description: "Optional nullable field did not preserve explicit null.")
}
let constructed = PersonSchema.Value(
  name: "Grace", address: .init(street: "Second"), nickname: nil)
try check(
  constructed.contact == nil, "An absent-capable initializer argument should default to nil.")
requireSendable(constructed)
try reject(PersonSchema.schema, #"{"name":"Ada","address":{"street":"First"}}"#)
try reject(PersonSchema.schema, #"{"name":"Ada","address":{"street":1},"nickname":null}"#)

let singleton: SingletonSchema.Value = try SingletonSchema.schema.parseAndValidate(
  instance: #"{"name":"one"}"#)
try check(singleton.name == "one", "Singleton object was unwrapped.")
requireSendable(SingletonSchema.Value(name: "two"))
requireSendable(EmptySchema.Value())
_ = try EmptySchema.schema.parseAndValidate(instance: "{}")
try reject(EmptySchema.schema, #"{"extra":true}"#)

let records: RecordsSchema.Value = [
  RecordsSchema.Record(id: 1),
  RecordsSchema.Record(id: 2, label: "second"),
]
let parsedRecords = try RecordsSchema.schema.parseAndValidate(instance: #"[{"id":1},{"id":2}]"#)
try check(records[1].label == "second" && parsedRecords[0].id == 1, "Named array items failed.")
requireSendable(records)
try reject(RecordsSchema.schema, #"[{"id":"bad"}]"#)

let dictionary: DictionarySchema.Value = [
  "first": DictionarySchema.Entry(code: 7)
]
let parsedDictionary = try DictionarySchema.schema.parseAndValidate(
  instance: #"{"first":{"code":7}}"#)
try check(
  dictionary["first"]?.code == parsedDictionary["first"]?.code, "Named dictionary values failed.")
requireSendable(dictionary)
try reject(DictionarySchema.schema, #"{"first":{"code":false}}"#)

let extras = try ExtrasSchema.schema.parseAndValidate(
  instance: #"{"name":"mixed","token":3,"other":4,"type":5,"x-enabled":true}"#)
try check(extras.name == "mixed" && extras.token == .integer(3), "Required-only property was lost.")
try check(
  extras.additionalProperties == ["token": 3, "other": 4, "type": 5],
  "Additional values must exclude declared and pattern-covered names, but include required-only names."
)
let collision = try ExtrasCollisionSchema.schema.parseAndValidate(
  instance: #"{"additionalProperties":"literal","count":2}"#)
try check(
  collision.additionalProperties == "literal", "A real JSON field lost its preserved label.")
try check(
  collision.additionalProperties_2 == ["count": 2],
  "Synthesized extra values collided with a field.")
try reject(ExtrasSchema.schema, #"{"name":"mixed","token":3,"other":"bad"}"#)

let awkward = try AwkwardKeysSchema.schema.parseAndValidate(
  instance:
    #"{"":"empty","property":"literal","$id":1,"id":2,"class":true,"a-b":3,"a_b":4,"e\u0301":"unicode"}"#
)
try check(
  awkward.property_2 == "empty" && awkward.property == "literal", "Empty-key labels changed.")
try check(
  awkward.id_2 == 1 && awkward.id == 2 && awkward.class, "Reserved/valid field labels changed.")
try check(
  awkward.a_b_2 == 3 && awkward.a_b == 4 && awkward.e == "unicode",
  "Normalized field labels changed.")

let response: ResponseSchema.Value = try ResponseSchema.schema.parseAndValidate(
  instance: #"{"state":"ready","payload":"done"}"#)
guard case .ready(let ready) = response else {
  throw ConsumerFailure(
    description: "Required discriminator did not select the semantic ready case.")
}
try check(ready.payload == "done", "Union payload is not a named object.")
requireSendable(ResponseSchema.Value.pending(.init(state: "pending", retryAfter: 3)))
try reject(ResponseSchema.schema, #"{"state":"ready","retryAfter":3}"#)

let memberKeywords = try MemberKeywordsSchema.schema.parseAndValidate(
  instance: #"{"self":1,"Self":2,"init":3,"deinit":4,"Type":5,"Protocol":6,"_self":7,"_self_2":8}"#)
try check(
  memberKeywords.`self` == 1 && memberKeywords.`Self` == 2, "Self-like field names changed.")
try check(
  memberKeywords._self == 7 && memberKeywords._self_2 == 8,
  "Internal parameter naming collided with real fields.")
try check(
  memberKeywords.`init` == 3 && memberKeywords.`deinit` == 4,
  "Initializer-like field names changed.")
try check(
  memberKeywords.`Type` == 5 && memberKeywords.`Protocol` == 6, "Metatype-like field names changed."
)

let lower: LowercaseNameSchema.value = .init(number: 9)
let lowercaseModel = try LowercaseNameSchema.schema.parseAndValidate(
  instance: #"{"child":{"number":9}}"#)
try check(
  lowercaseModel.child.number == lower.number,
  "An explicit lowercase type name shadowed a parser binding.")

let overlap = try OverlapSchema.schema.parseAndValidate(instance: #"{"x":1,"y":2}"#)
guard case .left(let firstMatch) = overlap else {
  throw ConsumerFailure(description: "anyOf must preserve first-valid-branch selection.")
}
try check(firstMatch.x == 1, "anyOf first branch lost its typed payload.")

let equalShapes = try EqualShapesSchema.schema.parseAndValidate(
  instance: #"{"state":"rejected","code":9}"#)
guard case .rejected(let rejected) = equalShapes else {
  throw ConsumerFailure(
    description: "Distinct equal-shaped object alternatives lost their nominal identity.")
}
let rejectedModel: EqualShapesSchema.Rejected = rejected
try check(rejectedModel.code == 9, "Equal-shaped branch payload changed.")

let scalarNull: ScalarsSchema.Value = try ScalarsSchema.schema.parseAndValidate(instance: "null")
guard case .null = scalarNull else {
  throw ConsumerFailure(description: "Mixed scalar null should be a no-payload null case.")
}
let scalarNumber = try ScalarsSchema.schema.parseAndValidate(instance: "1.5")
guard case .number(1.5) = scalarNumber else {
  throw ConsumerFailure(description: "Mixed scalar number lost its semantic case.")
}
let nullable: NullableScalarSchema.Value = nil
let nullableString: NullableScalarSchema.Value = "value"
try check(
  nullable == nil && nullableString == "value", "Nullable scalar must remain an Optional alias.")
let null: NullSchema.Value = try NullSchema.schema.parseAndValidate(instance: "null")
requireSendable(null)
let anything: AnythingSchema.Value = .object(["anything": .boolean(true)])
try check(
  anything.object?["anything"] == .boolean(true), "Untyped schema must remain a JSONValue alias.")
let prefix: PrefixSchema.Value = try PrefixSchema.schema.parseAndValidate(
  instance: #"["first",2,true]"#)
try check(
  prefix == [.string("first"), .integer(2), .boolean(true)],
  "Prefix arrays must remain JSONValue arrays.")
try reject(PrefixSchema.schema, #"["first","bad",true]"#)

let tree: RecursiveTreeSchema.Value = try RecursiveTreeSchema.schema.parseAndValidate(
  instance: #"{"value":"root","children":[{"value":"leaf","children":[]}]}"#)
try check(
  tree.children.first?.value == "leaf", "Recursive child required a public reference wrapper.")
try check(
  Mirror(reflecting: tree).displayStyle == .struct, "Array indirection should preserve structs.")
let builtTree = RecursiveTreeSchema.Value(
  value: "root", children: [.init(value: "leaf", children: [])])
requireSendable(builtTree)
try reject(RecursiveTreeSchema.schema, #"{"value":"root","children":[{"value":0,"children":[]}]}"#)

let list: LinkedListSchema.Value = try LinkedListSchema.schema.parseAndValidate(
  instance: #"{"value":1,"next":{"value":2,"next":null}}"#)
try check(list?.next?.value == 2, "Nullable recursive class requires a public reference wrapper.")
try check(list?.next?.next == nil, "Nullable recursion did not terminate.")
try check(
  Mirror(reflecting: list!).displayStyle == .class,
  "Inline object cycle did not use explicit class policy.")
requireSendable(list)
try reject(LinkedListSchema.schema, #"{"value":1,"next":{"value":"bad","next":null}}"#)

let mutual: MutualSchema.Value = try MutualSchema.schema.parseAndValidate(
  instance: #"{"name":"outer","b":{"count":2,"a":{"name":"inner"}}}"#)
try check(mutual.b?.a?.name == "inner", "Mutually recursive public model graph is incorrect.")
try check(
  Mirror(reflecting: mutual).displayStyle == .class,
  "Mutual inline cycle should use explicit classes.")
requireSendable(mutual)

let recursiveUnion: RecursiveUnionSchema.Value = try RecursiveUnionSchema.schema.parseAndValidate(
  instance: #"{"not":{"not":false}}"#)
guard case .object(let outer) = recursiveUnion,
  case .some(.object(let inner)) = outer.not,
  case .some(.boolean(false)) = inner.not
else {
  throw ConsumerFailure(
    description: "Natural recursive union exposed wrappers or changed semantic cases.")
}
try check(
  Mirror(reflecting: outer).displayStyle == .struct,
  "An indirect union should retain object value semantics.")
requireSendable(recursiveUnion)
try reject(RecursiveUnionSchema.schema, #"{"not":{"not":17}}"#)

let dynamic: DynamicTreeSchema.Value = try DynamicTreeSchema.schema.parseAndValidate(
  instance:
    #"{"value":"root","extra":true,"children":[{"value":"leaf","extra":false,"children":[]}]}"#)
try check(
  dynamic.extra && dynamic.children.first?.extra == false,
  "Dynamic specialization lost the strict child shape.")
requireSendable(dynamic)
try reject(
  DynamicTreeSchema.schema,
  #"{"value":"root","extra":true,"children":[{"value":"leaf","children":[]}]}"#)

let openAPI = try OpenAPIOptionsSchema.schema.parseAndValidate(
  instance: #"{"payload":{"number":11},"result":12}"#)
let message: OpenAPIOptionsSchema.Message = openAPI.payload
guard case .count(12) = openAPI.result else {
  throw ConsumerFailure(
    description: "OpenAPI case overrides did not preserve original component selectors.")
}
requireSendable(OpenAPIOptionsSchema.Outcome.text("value"))
try check(message.number == 11, "OpenAPI type override did not reach the nested model.")

print(
  "Named-model consumer passed: public models, constructors, semantic unions, recursion, nullability, extras, and validation parity."
)
