import CustomDump
import Foundation
import Testing

@testable import JSONSchemaCodegenCore

struct SharedSchemaGenerationTests {
  private func generate(
    _ source: String, pointers: [String], names: [String],
    options: SchemaGenerationOptions = .init()
  ) throws -> GeneratedSharedSchemas {
    try SchemaGenerator(options: options).generateShared(
      document: .init(
        source: source, retrievalURI: URL(string: "https://example.com/container.json")!),
      schemaPointers: pointers, rootNames: names)
  }

  private func text(_ result: GeneratedSharedSchemas) -> String {
    result.declarations.joined(separator: "\n").replacingOccurrences(of: "`", with: "")
  }

  @Test func listAndRetrieveShareCanonicalModelWithoutSelectingItsDefinition() throws {
    let result = try generate(
      ##"""
      {
        "components":{"schemas":{
          "Model":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]},
          "Twin":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}
        }},
        "retrieve":{"$ref":"#/components/schemas/Model"},
        "list":{"type":"array","items":{"$ref":"#/components/schemas/Model"}},
        "twin":{"$ref":"#/components/schemas/Twin"}
      }
      """##,
      pointers: ["/retrieve", "/list", "/twin"],
      names: ["Retrieve", "List", "Other"])
    expectNoDifference(result.roots.map(\.name), ["Retrieve", "List", "Other"])
    expectNoDifference(result.roots.map(\.outputType), ["Retrieve", "List", "Other"])
    expectNoDifference(result.roots[0].encodingExpression, "Self.encodeRetrieve")
    let output = text(result)
    #expect(output.contains("typealias Retrieve = Model"))
    #expect(output.contains("typealias List = [Model]"))
    #expect(output.contains("typealias Other = Twin"))
    expectNoDifference(output.components(separatedBy: "struct Model:").count, 2)
    #expect(output.contains("struct Twin:"))
    #expect(output.contains("func encodeRetrieve(_ value: Retrieve) throws -> JSONValue"))
    #expect(!output.contains("typealias Value"))
  }

  @Test func recursiveModelsAndTheirArrayItemsShareOneAdapterSpace() throws {
    let result = try generate(
      ##"""
      {
        "defs":{
          "Tree":{"type":"object","properties":{"children":{"type":"array","items":{"$ref":"#/defs/Tree"}}},"required":["children"]},
          "Other":{"type":"object","properties":{"nodes":{"type":"array","items":{"$ref":"#/defs/Other"}}},"required":["nodes"]}
        },
        "one":{"$ref":"#/defs/Tree"},
        "many":{"type":"array","items":{"$ref":"#/defs/Tree"}},
        "other":{"$ref":"#/defs/Other"}
      }
      """##,
      pointers: ["/one", "/many", "/other"], names: ["One", "Many", "OtherRoot"])
    let output = text(result)
    #expect(output.contains("typealias Many = ["))
    expectNoDifference(output.components(separatedBy: "let children:").count, 2)
    expectNoDifference(output.components(separatedBy: "let nodes:").count, 2)
    #expect(!output.contains("public indirect enum Reference"))
    #expect(output.contains("_JSONSchemaCodegenMakeReference1"))
    #expect(output.contains("_JSONSchemaCodegenMakeReference2"))
  }

  @Test func encodersRetainPresenceKeysEnumsAndTypedExtras() throws {
    let result = try generate(
      #"""
      {"schema":{"type":"object","properties":{
        "wire-key":{"type":"string"},
        "contact":{"type":["string","null"]},
        "nickname":{"type":["string","null"]},
        "choice":{"type":"string","enum":["é","e\u0301"]},
        "additionalProperties":{"type":"string"}
      },"required":["wire-key","nickname","token"],"additionalProperties":{"type":"integer"}}}
      """#,
      pointers: ["/schema"], names: ["Request"])
    let output = text(result)
    #expect(output.contains("let contact: String??"))
    #expect(output.contains("let nickname: String?"))
    #expect(output.contains("let token: JSONValue"))
    #expect(output.contains("if let present = value.contact"))
    #expect(output.contains(#"object["wire-key"] = .string(value.wire_key)"#))
    #expect(output.contains("value.additionalProperties_2"))
    #expect(output.contains("Additional property collides"))
    #expect(output.contains(".string(value.rawValue)"))
    #expect(output.contains("unicodeScalars.elementsEqual"))
  }

  @Test func refinementsAreDistinctButUnrefinedUseSitesShare() throws {
    let result = try generate(
      ##"""
      {"defs":{"Item":{"type":"object","properties":{"id":{"type":"integer"}}}},
       "a":{"$ref":"#/defs/Item"},
       "b":{"$ref":"#/defs/Item","description":"annotation"},
       "c":{"$ref":"#/defs/Item","required":["id"]}}
      """##,
      pointers: ["/a", "/b", "/c"], names: ["First", "Second", "Refined"])
    let output = text(result)
    expectNoDifference(output.components(separatedBy: "public struct ").count, 3)
    #expect(output.contains("let id: Int?"))
    #expect(output.contains("let id: Int\n"))
    let aliases = result.declarations.filter { $0.contains("typealias") }
    expectNoDifference(
      aliases[0].components(separatedBy: " = ").last,
      aliases[1].components(separatedBy: " = ").last)
  }

  @Test func scalarContainersAndUnconstrainedValuesAreEncodable() throws {
    let result = try generate(
      #"""
      {"roots":[true,{"type":"number"},{"type":"null"},
        {"type":"object","additionalProperties":{"type":"boolean"}},
        {"type":"array","prefixItems":[{"type":"string"}]},
        {"type":["string","integer","null"]}]}
      """#,
      pointers: (0...5).map { "/roots/\($0)" },
      names: ["Anything", "NumberRoot", "NullRoot", "DictionaryRoot", "PrefixRoot", "UnionRoot"])
    let output = text(result)
    #expect(output.contains("typealias Anything = JSONValue"))
    #expect(output.contains("typealias NumberRoot = Double"))
    #expect(output.contains("typealias NullRoot = Void"))
    #expect(output.contains("typealias DictionaryRoot = [String: Bool]"))
    #expect(output.contains("typealias PrefixRoot = [JSONValue]"))
    #expect(output.contains("guard value.isFinite"))
    #expect(output.contains("case .null:"))
    #expect(output.contains("return .null"))
  }

  @Test func invalidRootNamesAndCountsAreLocated() throws {
    for names in [
      ["Same", "Same"], ["String", "Other"], ["Thing", "encodeThing"],
      ["bad-name", "Other"], ["_JSONSchemaCodegenRoot", "Other"], ["schema", "Other"],
    ] {
      #expect(throws: SchemaGenerationError.self) {
        try generate(#"{"a":{},"b":{}}"#, pointers: ["/a", "/b"], names: names)
      }
    }
    #expect(throws: SchemaGenerationError.self) {
      try generate(#"{"a":{}}"#, pointers: ["/a"], names: [])
    }
    expectNoDifference(
      try generate("{}", pointers: [], names: []).declarations, [])
  }

  @Test func emptyRootAndEscapedPointersWork() throws {
    let scalar = try generate(#"{"type":"string"}"#, pointers: [""], names: ["Root"])
    #expect(text(scalar).contains("typealias Root = String"))
    let escaped = try generate(
      #"{"a/b":{"~":{"type":"boolean"}}}"#, pointers: ["/a~1b/~0"], names: ["Root"])
    #expect(text(escaped).contains("typealias Root = Bool"))
  }

  @Test func unsupportedEncodingReportsSourceInsteadOfEmittingWrongJSON() throws {
    let provenance = SchemaModelProvenance(
      identity: "unsupported",
      origins: [
        .init(
          pointer: "/request", documentURI: nil, logicalDocument: "document",
          resource: "document#/request")
      ])
    do {
      _ = try SchemaEncodingSyntax(graph: .init(), names: [:], cases: [:])
        .rootDeclaration(name: "Request", output: .named("Unsupported"), provenance: provenance)
      Issue.record("Unsupported output unexpectedly received an encoder.")
    } catch let error as SchemaGenerationError {
      expectNoDifference(error.pointer, "/request")
      #expect(error.message.contains("encoding"))
    }
  }

  @Test func selectedAndLazilyIndexedReferencesHaveIdenticalCanonicalIdentity() throws {
    let source = ##"""
      {
        "components":{"schemas":{"Item":{"type":"object","properties":{"id":{"type":"integer"}}}}},
        "one":{"$ref":"#/components/schemas/Item"},
        "two":{"$ref":"#/components/schemas/%49tem"}
      }
      """##
    let selected = try generate(
      source, pointers: ["/two", "/components/schemas/Item", "/one"],
      names: ["Second", "Direct", "First"])
    let lazy = try generate(source, pointers: ["/two", "/one"], names: ["Second", "First"])
    let selectedModels = selected.declarations.filter {
      $0.replacingOccurrences(of: "`", with: "").contains("public struct Item:")
    }
    let lazyModels = lazy.declarations.filter {
      $0.replacingOccurrences(of: "`", with: "").contains("public struct Item:")
    }
    expectNoDifference(selectedModels, lazyModels)
    expectNoDifference(selectedModels.count, 1)
    expectNoDifference(text(lazy).components(separatedBy: "public struct ").count, 2)
    #expect(text(selected).contains("typealias Direct = Item"))
  }

  @Test func overlappingSelectedRootsPreserveNestedResourceBases() throws {
    let source = ##"""
      {"schema":{
        "$id":"https://example.com/nested",
        "$defs":{"Item":{"type":"object","properties":{"id":{"type":"integer"}}}},
        "type":"object",
        "properties":{"item":{"$ref":"#/$defs/Item"}}
      }}
      """##
    let forward = try generate(
      source, pointers: ["/schema", "/schema/$defs/Item"], names: ["Container", "Direct"])
    let reverse = try generate(
      source, pointers: ["/schema/$defs/Item", "/schema"], names: ["Direct", "Container"])
    expectNoDifference(
      forward.declarations.filter { !$0.contains("typealias") && !$0.contains("func encode") },
      reverse.declarations.filter { !$0.contains("typealias") && !$0.contains("func encode") })
    expectNoDifference(text(forward).components(separatedBy: "struct Item:").count, 2)
  }

  @Test func untypedObjectKeywordsGetDisjointTypedAndNonObjectOutputsOnlyInSharedMode() throws {
    let source = #"""
      {"properties":{"id":{"type":"string"},"created":{"type":"integer"}},
       "required":["id","created"],"description":"No implicit type restriction"}
      """#
    let shared = try generate(source, pointers: [""], names: ["Root"])
    let output = text(shared)
    #expect(output.contains("case object(ModelObject)"))
    #expect(output.contains("case nonObject(JSONValue)"))
    #expect(output.contains("struct ModelObject"))
    #expect(output.contains("let id: String"))
    #expect(output.contains("let created: Int"))
    #expect(output.contains("guard payload.object == nil"))
    #expect(shared.roots[0].expression.contains("JSONComposition.Not"))
    #expect(shared.roots[0].expression.contains("_schemaWithDefinition"))
    expectNoDifference(try SchemaGenerator().generate(source).outputType, "JSONValue")
    let named = try SchemaGenerator(options: .init(output: .models)).generate(source)
    expectNoDifference(named.declarations.first, "public typealias Value = JSONValue")
    #expect(!named.declarations.contains { $0.contains("struct ModelObject") })
  }

  @Test func untypedReferencedObjectWrappersShareWithListItemsAndKeepOverrides() throws {
    let result = try generate(
      ##"""
      {"components":{"schemas":{"Model":{
        "properties":{"id":{"type":"string"}},"required":["id"]
      }}},
      "retrieve":{"$ref":"#/components/schemas/Model"},
      "list":{"type":"array","items":{"$ref":"#/components/schemas/Model"}}}
      """##,
      pointers: ["/retrieve", "/list"], names: ["Retrieve", "List"],
      options: .init(names: .init(typeNames: ["#/components/schemas/Model": "SharedModel"])))
    let output = text(result)
    #expect(output.contains("typealias Retrieve = SharedModel"))
    #expect(output.contains("typealias List = [SharedModel]"))
    #expect(output.contains("case object(ModelObject)"))
    expectNoDifference(output.components(separatedBy: "enum SharedModel:").count, 2)
    expectNoDifference(output.components(separatedBy: "struct ModelObject:").count, 2)
  }

  @Test func largeSharedValidationUsesLosslessConstantsWithoutChangingDefaultEmission() throws {
    let source = """
      {"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],
       "unevaluatedProperties":false,"x-padding":"\(String(repeating: "x", count: 5_000))"}
      """
    let shared = try generate(source, pointers: [""], names: ["Root"])
    let output = text(shared)
    #expect(output.contains("private static let _JSONSchemaCodegenDefinition1: SchemaValue"))
    #expect(output.contains("JSONValue.parse("))
    #expect(output.contains("preconditionFailure"))
    #expect(shared.roots[0].expression.contains("_JSONSchemaCodegenDefinition1"))
    #expect(output.contains("let id: Int"))
    #expect(output.contains("func encodeRoot"))
    expectNoDifference(shared, try generate(source, pointers: [""], names: ["Root"]))
    let legacy = try SchemaGenerator().generate(source)
    #expect(!legacy.declarations.contains { $0.contains("JSONValue.parse(") })
    #expect(legacy.expression.contains(".object(["))
    let small = try generate(
      #"{"type":"object","unevaluatedProperties":false}"#, pointers: [""], names: ["Small"])
    #expect(!text(small).contains("JSONValue.parse("))
  }

  @Test func wideSharedGraphRetainsDistinctReferenceIdentitiesAcrossRewrittenFields() throws {
    let definition = #"""
      {"type":"object","properties":{"kind":{"type":"string","enum":["first","second"]}},
       "required":["kind"],"additionalProperties":false}
      """#
    let fields = (0..<8).map { index in
      """
      "left\(index)":{"$ref":"#/$defs/Left"},"right\(index)":{"$ref":"#/$defs/Right"}
      """
    }.joined(separator: ",")
    let roots = (0..<16).map { index in
      "\"root\(index)\":{\"type\":\"object\",\"properties\":{\(fields)}}"
    }.joined(separator: ",")
    let source = "{\"$defs\":{\"Left\":\(definition),\"Right\":\(definition)},\(roots)}"
    let names = (0..<16).map { "Root\($0)" }
    let pointers = (0..<16).map { "/root\($0)" }
    let result = try generate(source, pointers: pointers, names: names)
    let output = text(result)
    expectNoDifference(result.roots.map(\.outputType), names)
    expectNoDifference(output.components(separatedBy: "struct Left:").count, 2)
    expectNoDifference(output.components(separatedBy: "struct Right:").count, 2)
    for index in 0..<8 {
      expectNoDifference(output.components(separatedBy: "let left\(index): Left?").count, 17)
      expectNoDifference(output.components(separatedBy: "let right\(index): Right?").count, 17)
    }
    expectNoDifference(result, try generate(source, pointers: pointers, names: names))
  }
}
