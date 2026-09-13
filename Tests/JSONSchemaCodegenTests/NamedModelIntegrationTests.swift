import CustomDump
import JSONSchemaCodegen
import Testing

@Schema(
  #"{"type":"object","properties":{"child":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]},"requiredNullable":{"type":["integer","null"]},"optionalNullable":{"type":["integer","null"]}},"required":["child","requiredNullable"]}"#,
  output: .models)
private enum NamedPresence {}

@Schema(#"{"type":"object","additionalProperties":false}"#, output: .models)
private enum NamedEmpty {}

@Schema(
  #"{"type":"object","properties":{"additionalProperties":{"type":"string"}},"required":["additionalProperties","token"],"patternProperties":{"^x-":{"type":"boolean"}},"additionalProperties":{"type":"integer"}}"#,
  output: .models)
private enum NamedExtras {}

@Schema(
  #"{"type":"object","properties":{"known":{"type":["string","null"]}},"patternProperties":{"^skip-":{"type":"boolean"}},"additionalProperties":{"type":"integer"}}"#,
  output: .models)
private enum NamedSingleExtra {}

@Schema(
  #"{"type":"object","properties":{"known":{"type":["string","null"]}},"patternProperties":{"^skip-":{"type":"boolean"}},"additionalProperties":{"type":"integer"}}"#
)
private enum NamedSingleExtraTuples {}

@Schema(
  #"{"type":"object","anyOf":[{"properties":{"x":{"type":"integer"}},"required":["x"]},{"properties":{"y":{"type":"integer"}},"required":["y"]}]}"#,
  output: .models, caseNames: ["#/anyOf/0": "left", "#/anyOf/1": "right"])
private enum NamedOrderedUnion {}

@Schema(
  ##"{"type":"object","properties":{"value":{"type":"integer"},"children":{"type":"array","items":{"$ref":"#"}}},"required":["value","children"]}"##,
  output: .models)
private enum NamedTree {}

@Schema(
  ##"{"type":["object","null"],"properties":{"value":{"type":"integer"},"next":{"$ref":"#"}},"required":["value","next"]}"##,
  output: .models, recursiveObjects: .immutableClasses)
private enum NamedList {}

@Schema(
  ##"{"type":["object","boolean"],"properties":{"not":{"$ref":"#"}}}"##,
  output: .models)
private enum NamedRecursiveUnion {}

@Schema(
  ##"{"type":"object","$defs":{"fields":{"properties":{"bar":{"type":"integer"}}}},"$ref":"#/$defs/fields","properties":{"foo":{"type":"string"}},"unevaluatedProperties":false}"##,
  output: .models)
private enum NamedSiblingScope {}

@Schema(
  ##"{"$id":"https://example.com/named-dynamic","$dynamicAnchor":"node","$ref":"tree","properties":{"extra":{"type":"boolean"}},"required":["extra"],"$defs":{"tree":{"$id":"tree","$dynamicAnchor":"node","type":"object","properties":{"children":{"type":"array","items":{"$dynamicRef":"#node"}}},"required":["children"]}}}"##,
  output: .models)
private enum NamedDynamicTree {}

@Schema(
  ##"{"$ref":"#/$defs/node","$defs":{"node":{"type":["object","null"],"properties":{"value":{"type":"integer"},"next":{"$ref":"#/$defs/node","properties":{"tag":{"type":"string"}},"required":["tag"]}},"required":["value","next"]}}}"##,
  output: .models, recursiveObjects: .immutableClasses)
private enum NamedRefinedList {}

@Schema(
  #"{"type":"object","properties":{"class":{"type":"string"},"inout":{"type":"integer"},"init":{"type":"boolean"}},"required":["class","inout","init"]}"#,
  output: .models)
private enum NamedKeywordFields {}

@Schema(
  #"{"type":"object","properties":{"self":{"type":"integer"},"_self":{"type":"integer"},"_self_2":{"type":"integer"},"Self":{"type":"integer"},"init":{"type":"integer"},"Type":{"type":"integer"}},"required":["self","_self","_self_2","Self","init","Type"]}"#,
  output: .models)
private enum NamedSelfFields {}

@Schema(
  #"{"type":"object","properties":{"child":{"type":"object","properties":{"number":{"type":"integer"}},"required":["number"]}},"required":["child"]}"#,
  output: .models, typeNames: ["#/properties/child": "value"])
private enum NamedLowercaseType {}

@Schema(#"{"type":"integer"}"#, output: .models)
private enum NamedExactInteger {}

@Schema(
  #"{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}}"#,
  output: .models)
private enum NamedObjectArray {}

@Schema(
  #"{"type":"object","additionalProperties":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}}"#,
  output: .models)
private enum NamedObjectDictionary {}

@Schema(
  ##"{"$ref":"#/$defs/A","$defs":{"A":{"type":"object","properties":{"b":{"$ref":"#/$defs/B"}}},"B":{"type":"object","properties":{"a":{"$ref":"#/$defs/A"}}}}}"##,
  output: .models, recursiveObjects: .immutableClasses)
private enum NamedMutualObjects {}

struct NamedModelIntegrationTests {
  @Test func constructedModelsAndFourPresenceStates() throws {
    let absent = try NamedPresence.schema.parseAndValidate(
      instance: #"{"child":{"name":"Ada"},"requiredNullable":null}"#)
    expectNoDifference(absent.child.name, "Ada")
    #expect(absent.requiredNullable == nil)
    #expect(absent.optionalNullable == nil)
    let explicitNull = try NamedPresence.schema.parseAndValidate(
      instance: #"{"child":{"name":"Ada"},"requiredNullable":4,"optionalNullable":null}"#)
    guard case .some(.none) = explicitNull.optionalNullable else {
      Issue.record("Explicit null must retain the outer presence Optional.")
      return
    }
    let constructed = NamedPresence.Value(child: .init(name: "Grace"), requiredNullable: nil)
    expectNoDifference(constructed.child.name, "Grace")
    #expect(constructed.optionalNullable == nil)
    #expect(throws: (any Error).self) {
      try NamedPresence.schema.parseAndValidate(instance: #"{"child":{"name":"Ada"}}"#)
    }
  }

  @Test func emptyAndSingletonConstructorCompilation() throws {
    let _: NamedEmpty.Value = .init()
    _ = try NamedEmpty.schema.parseAndValidate(instance: "{}")
    #expect(throws: (any Error).self) {
      try NamedEmpty.schema.parseAndValidate(instance: #"{"extra":true}"#)
    }
  }

  @Test func singleRawFieldWithExtrasPreservesNullPresenceAndValidation() throws {
    let explicitNull = try NamedSingleExtra.schema.parseAndValidate(
      instance: #"{"known":null,"other":3,"skip-flag":true}"#)
    guard case .some(.none) = explicitNull.known else {
      Issue.record("Raw single-field projection must retain explicit null.")
      return
    }
    expectNoDifference(explicitNull.additionalProperties, ["other": 3])
    let absent = try NamedSingleExtra.schema.parseAndValidate(instance: #"{"other":4}"#)
    #expect(absent.known == nil)
    expectNoDifference(absent.additionalProperties, ["other": 4])
    let string = try NamedSingleExtra.schema.parseAndValidate(instance: #"{"known":"present"}"#)
    guard case .some(.some("present")) = string.known else {
      Issue.record("Raw single-field projection must retain the parsed value.")
      return
    }
    #expect(throws: (any Error).self) {
      try NamedSingleExtra.schema.parseAndValidate(instance: #"{"other":"bad"}"#)
    }
    expectNoDifference(
      NamedSingleExtra.schema.schemaValue, NamedSingleExtraTuples.schema.schemaValue)
  }

  @Test func extrasPreserveCoverageAndRequiredOnlyFields() throws {
    let parsed = try NamedExtras.schema.parseAndValidate(
      instance: #"{"additionalProperties":"literal","token":3,"other":4,"x-flag":true}"#)
    expectNoDifference(parsed.additionalProperties, "literal")
    expectNoDifference(parsed.token, .integer(3))
    expectNoDifference(parsed.additionalProperties_2, ["token": 3, "other": 4])
  }

  @Test func anyOfKeepsFirstValidBranch() throws {
    let parsed = try NamedOrderedUnion.schema.parseAndValidate(instance: #"{"x":1,"y":2}"#)
    guard case .left(let first) = parsed else {
      Issue.record("anyOf must select its first valid branch.")
      return
    }
    expectNoDifference(first.x, 1)
  }

  @Test func treeRecursionUsesPublicModelsDirectly() throws {
    let parsed = try NamedTree.schema.parseAndValidate(
      instance: #"{"value":1,"children":[{"value":2,"children":[]}]}"#)
    expectNoDifference(parsed.children[0].value, 2)
    let _: NamedTree.Value = .init(value: 1, children: [.init(value: 2, children: [])])
    #expect(throws: (any Error).self) {
      try NamedTree.schema.parseAndValidate(
        instance: #"{"value":1,"children":[{"value":"bad","children":[]}]}"#)
    }
  }

  @Test func nullableLinkedListUsesImmutableClass() throws {
    let parsed = try NamedList.schema.parseAndValidate(
      instance: #"{"value":1,"next":{"value":2,"next":null}}"#)
    expectNoDifference(parsed?.next?.value, 2)
    #expect(parsed?.next?.next == nil)
    #expect(Mirror(reflecting: try #require(parsed)).displayStyle == .class)
  }

  @Test func naturalUnionPreservesStructObjects() throws {
    let parsed = try NamedRecursiveUnion.schema.parseAndValidate(
      instance: #"{"not":{"not":false}}"#)
    guard case .object(let outer) = parsed,
      case .some(.object(let inner)) = outer.not,
      case .some(.boolean(false)) = inner.not
    else {
      Issue.record("Semantic recursion must not expose parser adapters.")
      return
    }
    #expect(Mirror(reflecting: outer).displayStyle == .struct)
  }

  @Test func referenceSiblingAnnotationScopeIsUnchanged() throws {
    let parsed = try NamedSiblingScope.schema.parseAndValidate(instance: #"{"foo":"x","bar":2}"#)
    expectNoDifference(parsed.foo, "x")
    expectNoDifference(parsed.bar, 2)
    #expect(throws: (any Error).self) {
      try NamedSiblingScope.schema.parseAndValidate(instance: #"{"foo":"x","bar":2,"other":true}"#)
    }
  }

  @Test func dynamicTargetsUnifyWithRefinedRoot() throws {
    let parsed = try NamedDynamicTree.schema.parseAndValidate(
      instance: #"{"extra":true,"children":[{"extra":false,"children":[]}]}"#)
    expectNoDifference(parsed.children[0].extra, false)
    #expect(throws: (any Error).self) {
      try NamedDynamicTree.schema.parseAndValidate(
        instance: #"{"extra":true,"children":[{"children":[]}]}"#)
    }
  }

  @Test func recursiveUseSiteRefinementsHaveTheirOwnOutput() throws {
    let parsed = try NamedRefinedList.schema.parseAndValidate(
      instance: #"{"value":1,"next":{"value":2,"tag":"refined","next":null}}"#)
    expectNoDifference(parsed?.next?.tag, "refined")
    #expect(throws: (any Error).self) {
      try NamedRefinedList.schema.parseAndValidate(
        instance: #"{"value":1,"next":{"value":2,"next":null}}"#)
    }
  }

  @Test func escapedFieldNamesRemainConstructible() throws {
    let parsed = try NamedKeywordFields.schema.parseAndValidate(
      instance: #"{"class":"example","inout":3,"init":true}"#)
    expectNoDifference(parsed.class, "example")
    expectNoDifference(parsed.inout, 3)
    expectNoDifference(parsed.`init`, true)
    let constructed = NamedKeywordFields.Value(class: "manual", `inout`: 4, init: false)
    expectNoDifference(constructed.inout, 4)
  }

  @Test func lowercaseTypeNameDoesNotCollideWithParserBinding() throws {
    let parsed = try NamedLowercaseType.schema.parseAndValidate(
      instance: #"{"child":{"number":42}}"#)
    expectNoDifference(parsed.child.number, 42)
    let child = NamedLowercaseType.value(number: 7)
    let constructed = NamedLowercaseType.Value(child: child)
    expectNoDifference(constructed.child.number, 7)
  }

  @Test func selfParameterDoesNotShadowTheConstructedInstance() throws {
    let parsed = try NamedSelfFields.schema.parseAndValidate(
      instance: #"{"self":1,"_self":2,"_self_2":3,"Self":4,"init":5,"Type":6}"#)
    expectNoDifference(parsed.`self`, 1)
    expectNoDifference(parsed._self, 2)
    expectNoDifference(parsed._self_2, 3)
    expectNoDifference(parsed.`Self`, 4)
    expectNoDifference(parsed.`init`, 5)
    expectNoDifference(parsed.`Type`, 6)
    let constructed = NamedSelfFields.Value(
      self: 7, _self: 8, _self_2: 9, Self: 10, init: 11, Type: 12)
    expectNoDifference(constructed.`self`, 7)
    expectNoDifference(constructed._self, 8)
  }

  @Test func rootContainerAliasesKeepNamedElements() throws {
    let array: NamedObjectArray.Value = try NamedObjectArray.schema.parseAndValidate(
      instance: #"[{"id":1},{"id":2}]"#)
    expectNoDifference(array.map(\.id), [1, 2])
    let dictionary: NamedObjectDictionary.Value = try NamedObjectDictionary.schema.parseAndValidate(
      instance: #"{"first":{"id":3}}"#)
    expectNoDifference(dictionary["first"]?.id, 3)
    let _: NamedObjectArray.Value = [.init(id: 1)]
    let _: NamedObjectDictionary.Value = ["first": .init(id: 1)]
  }

  @Test func primitiveAliasPreservesExactIntegers() throws {
    let value: NamedExactInteger.Value = try NamedExactInteger.schema.parseAndValidate(
      instance: "9007199254740993")
    expectNoDifference(value, 9_007_199_254_740_993)
    #expect(throws: (any Error).self) {
      try NamedExactInteger.schema.parseAndValidate(instance: "1.5")
    }
  }

  @Test func mutualObjectCyclesCompileAsCheckedSendableClasses() throws {
    let value = try NamedMutualObjects.schema.parseAndValidate(instance: #"{"b":{"a":{}}}"#)
    #expect(value.b?.a != nil)
    #expect(Mirror(reflecting: value).displayStyle == .class)
    #expect(Mirror(reflecting: try #require(value.b)).displayStyle == .class)
    func sendable<T: Sendable>(_: T) {}
    sendable(value)
  }
}
