import CustomDump
import Foundation
import Testing

@testable import JSONSchemaCodegenCore

struct RecursiveGraphTests {
  private func graph(_ source: String) throws -> ResolvedSchema {
    try SchemaReferenceGraph(
      documents: [.init(source: source, retrievalURI: URL(string: "https://example.com/root")!)]
    ).root(at: 0)
  }

  @Test func selfReferenceProducesFiniteDefinition() throws {
    let root = try graph(
      #"""
      {"type":"object","properties":{"next":{"$ref":"#"}}}
      """#)
    expectNoDifference(root.children["properties/next"]?.reference, "Reference1")
    expectNoDifference(root.recursiveDefinitions.count, 1)
    #expect(root.validationValue.object?["$defs"]?.object?["__codegen_Reference1"] != nil)
  }

  @Test func dynamicReferenceUsesOutermostResource() throws {
    let root = try graph(
      #"""
      {
        "$id":"https://example.com/root",
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
    let reference = try #require(root.children["properties/children"]?.children["items"]?.reference)
    let recursive = try #require(root.recursiveDefinitions[reference])
    #expect(recursive.refinements.contains { $0.value.object?["required"] != nil })
    #expect(!root.validationValue.description.contains("$dynamicRef"))
  }

  @Test func dynamicReferenceToStaticAnchorStaysStatic() throws {
    let root = try graph(
      #"""
      {
        "$dynamicAnchor":"node",
        "$defs":{"text":{"$anchor":"text","type":"string"}},
        "type":"array","items":{"$dynamicRef":"#text"}
      }
      """#)
    expectNoDifference(root.children["items"]?.value.object?["type"]?.string, "string")
    #expect(root.recursiveDefinitions.isEmpty)
  }

  @Test func referenceSiblingsRemainConjunctive() throws {
    let root = try graph(
      #"""
      {
        "$defs":{"a":{"type":"string"},"b":{"minLength":3}},
        "$ref":"#/$defs/a",
        "$dynamicRef":"#/$defs/b",
        "maxLength":10
      }
      """#)
    expectNoDifference(root.refinements.count, 2)
    #expect(root.validationValue.object?["allOf"] != nil)
  }

  @Test func distinctDynamicScopesDoNotShareCachedOutputs() throws {
    let root = try graph(
      #"""
      {
        "$id":"https://example.com/root",
        "$defs":{
          "strings":{
            "$id":"strings","$ref":"list",
            "$defs":{"item":{"$dynamicAnchor":"item","type":"string"}}
          },
          "integers":{
            "$id":"integers","$ref":"list",
            "$defs":{"item":{"$dynamicAnchor":"item","type":"integer"}}
          },
          "list":{
            "$id":"list","type":"array","items":{"$dynamicRef":"#item"},
            "$defs":{"item":{"$dynamicAnchor":"item"}}
          }
        },
        "allOf":[{"$ref":"strings"},{"$ref":"integers"}]
      }
      """#)
    expectNoDifference(
      root.children["allOf/0"]?.children["items"]?.value.object?["type"]?.string, "string")
    expectNoDifference(
      root.children["allOf/1"]?.children["items"]?.value.object?["type"]?.string, "integer")
  }

  @Test func validationSchemasIncludeEverySubschemaPosition() throws {
    for keyword in SchemaKeywords.singles {
      let root = try graph(
        """
        {"$defs":{"value":{"type":"integer"}},"\(keyword)":{"$ref":"#/$defs/value"}}
        """)
      expectNoDifference(root.validationValue.object?[keyword]?.object?["type"]?.string, "integer")
    }
    for keyword in ["patternProperties", "dependentSchemas"] {
      let root = try graph(
        """
        {"$defs":{"value":{"type":"integer"}},"\(keyword)":{"x":{"$ref":"#/$defs/value"}}}
        """)
      expectNoDifference(
        root.validationValue.object?[keyword]?.object?["x"]?.object?["type"]?.string, "integer")
    }
  }

  @Test func nonProgressingCyclesHaveExplicitErrors() {
    #expect(throws: SchemaGenerationError.self) {
      try graph(##"{"$ref":"#"}"##)
    }
  }
}
