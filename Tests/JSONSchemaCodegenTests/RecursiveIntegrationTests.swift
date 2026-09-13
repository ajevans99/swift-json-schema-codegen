import CustomDump
import JSONSchemaCodegen
import Testing

@Schema(
  #"""
  {
    "type":"object",
    "properties":{
      "value":{"type":"string"},
      "children":{"type":"array","items":{"$ref":"#"}}
    },
    "required":["value","children"]
  }
  """#)
private enum RecursiveTree {}

@Schema(
  #"""
  {
    "type":["object","null"],
    "properties":{
      "value":{"type":"integer"},
      "next":{"$ref":"#"}
    },
    "required":["value","next"]
  }
  """#)
private enum RecursiveList {}

@Schema(
  #"""
  {
    "$id":"https://example.com/strict-tree",
    "$dynamicAnchor":"node",
    "$ref":"tree",
    "required":["extra"],
    "$defs":{
      "tree":{
        "$id":"tree",
        "$dynamicAnchor":"node",
        "type":"object",
        "properties":{"children":{"type":"array","items":{"$dynamicRef":"#node"}}}
      }
    }
  }
  """#)
private enum DynamicTree {}

@Schema(
  #"""
  {
    "$id":"https://example.com/closed-tree",
    "$dynamicAnchor":"node",
    "$ref":"tree",
    "unevaluatedProperties":false,
    "$defs":{
      "tree":{
        "$id":"tree","$dynamicAnchor":"node","type":"object",
        "properties":{
          "data":true,
          "children":{"type":"array","items":{"$dynamicRef":"#node"}}
        }
      }
    }
  }
  """#)
private enum ClosedDynamicTree {}

@Schema(
  #"""
  {
    "type":"object",
    "$defs":{"fields":{"properties":{"bar":{"type":"integer"}}}},
    "$ref":"#/$defs/fields",
    "properties":{"foo":{"type":"string"}},
    "unevaluatedProperties":false
  }
  """#)
private enum ReferenceSiblingAnnotations {}

@Schema(
  #"""
  {
    "type":"object",
    "$defs":{"fields":{"properties":{"bar":true},"unevaluatedProperties":false}},
    "$ref":"#/$defs/fields",
    "properties":{"foo":true}
  }
  """#)
private enum ClosedReferenceTarget {}

@Schema(
  #"""
  {
    "type":"object",
    "properties":{"foo":{"type":"string"}},
    "anyOf":[
      {"properties":{"bar":{"type":"integer"}}},
      {"properties":{"baz":{"type":"boolean"}}}
    ],
    "unevaluatedProperties":false
  }
  """#)
private enum UnionSiblingAnnotations {}

@Schema(
  #"""
  {
    "$defs":{
      "a":{"properties":{"a":true}},
      "x":{"required":["x"],"properties":{"x":true}}
    },
    "allOf":[
      {"$ref":"#/$defs/a"},
      {"properties":{"b":true}},
      {"oneOf":[
        {"$ref":"#/$defs/x"},
        {"required":["y"],"properties":{"y":true}}
      ]}
    ],
    "unevaluatedProperties":false
  }
  """#)
private enum NestedUnionAnnotations {}

struct RecursiveIntegrationTests {
  @Test func recursiveObjectsHaveTypedChildren() throws {
    let root = try RecursiveTree.schema.parseAndValidate(
      instance: #"{"value":"root","children":[{"value":"child","children":[]}]}"#)
    expectNoDifference(root.value, "root")
    let first = try #require(root.children.first)
    switch first {
    case .value(let child):
      expectNoDifference(child.value, "child")
      #expect(child.children.isEmpty)
    }
    #expect(throws: ParseAndValidateIssue.self) {
      try RecursiveTree.schema.parseAndValidate(
        instance: #"{"value":"root","children":[{"value":42,"children":[]}]}"#)
    }
  }

  @Test func recursiveNullableValuesTerminate() throws {
    let list = try #require(
      try RecursiveList.schema.parseAndValidate(
        instance: #"{"value":1,"next":{"value":2,"next":null}}"#))
    expectNoDifference(list.value, 1)
    switch list.next {
    case .value(let nested):
      let next = try #require(nested)
      expectNoDifference(next.value, 2)
      switch next.next {
      case .value(let terminal): #expect(terminal == nil)
      }
    }
    #expect(try RecursiveList.schema.parseAndValidate(instance: "null") == nil)
  }

  @Test func dynamicReferencesKeepOuterConstraintsAtEveryDepth() throws {
    _ = try DynamicTree.schema.parseAndValidate(
      instance: #"{"extra":true,"children":[{"extra":true,"children":[]}]}"#)
    #expect(throws: ParseAndValidateIssue.self) {
      try DynamicTree.schema.parseAndValidate(
        instance: #"{"extra":true,"children":[{"children":[]}]}"#)
    }
    #expect(throws: ParseAndValidateIssue.self) {
      try DynamicTree.schema.parseAndValidate(
        instance: #"{"children":[]}"#)
    }
  }

  @Test func referenceSiblingsConsumeReferencedAnnotations() throws {
    let output = try ReferenceSiblingAnnotations.schema.parseAndValidate(
      instance: #"{"foo":"hello","bar":42}"#)
    expectNoDifference(output.foo, "hello")
    expectNoDifference(output.bar, 42)
    #expect(throws: ParseAndValidateIssue.self) {
      try ReferenceSiblingAnnotations.schema.parseAndValidate(
        instance: #"{"foo":"hello","bar":42,"extra":true}"#)
    }
    #expect(throws: ParseAndValidateIssue.self) {
      try ClosedReferenceTarget.schema.parseAndValidate(instance: #"{"foo":true,"bar":42}"#)
    }
  }

  @Test func recursiveUnevaluatedPropertiesShareReferenceAnnotations() throws {
    _ = try ClosedDynamicTree.schema.parseAndValidate(
      instance: #"{"data":1,"children":[{"data":2,"children":[]}]}"#)
    #expect(throws: ParseAndValidateIssue.self) {
      try ClosedDynamicTree.schema.parseAndValidate(
        instance: #"{"data":1,"children":[{"data":2,"misspelled":true}]}"#)
    }
  }

  @Test func unionBranchesDoNotReapplyRootUnevaluatedConstraints() throws {
    _ = try UnionSiblingAnnotations.schema.parseAndValidate(
      instance: #"{"foo":"hello","bar":42,"baz":true}"#)
    #expect(throws: ParseAndValidateIssue.self) {
      try UnionSiblingAnnotations.schema.parseAndValidate(
        instance: #"{"foo":"hello","bar":42,"extra":true}"#)
    }
  }

  @Test func nestedUnionProjectionsPreserveAnnotationScopes() throws {
    _ = try NestedUnionAnnotations.schema.parseAndValidate(instance: #"{"a":1,"b":1,"x":1}"#)
    _ = try NestedUnionAnnotations.schema.parseAndValidate(instance: #"{"a":1,"b":1,"y":1}"#)
    #expect(throws: ParseAndValidateIssue.self) {
      try NestedUnionAnnotations.schema.parseAndValidate(instance: #"{"a":1,"x":1,"y":1}"#)
    }
    #expect(throws: ParseAndValidateIssue.self) {
      try NestedUnionAnnotations.schema.parseAndValidate(instance: #"{"a":1,"x":1,"z":1}"#)
    }
  }
}
