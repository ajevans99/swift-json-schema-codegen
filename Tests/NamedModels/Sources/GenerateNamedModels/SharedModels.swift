import Foundation
import JSONSchemaCodegenCore

func generateSharedModels(output: URL) throws {
  let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures").standardizedFileURL
  let source = try String(
    contentsOf: fixtures.appendingPathComponent("shared.schema.json"), encoding: .utf8)
  let entries = [
    ("retrieve", "Retrieve"), ("create", "Create"), ("list", "List"), ("refined", "Refined"),
    ("only", "Only"), ("response", "Response"), ("anything", "Anything"), ("number", "NumberRoot"),
    ("prefix", "PrefixRoot"), ("nullable", "NullableRoot"), ("dictionary", "DictionaryRoot"),
    ("tree", "TreeRoot"), ("trees", "TreeList"), ("expression", "ExpressionRoot"),
    ("nulls", "NullArray"), ("nullDictionary", "NullDictionary"), ("nullFields", "NullFields"),
    ("empty", "EmptyRoot"),
  ]
  let generated = try SchemaGenerator().generateShared(
    document: .init(
      source: source, retrievalURI: URL(string: "https://example.com/shared.json")!),
    schemaPointers: entries.map { "/" + $0.0 }, rootNames: entries.map(\.1))
  try writeShared(generated, namespace: "SharedSchemas", output: output)

  let dynamic = ##"""
    {
      "base": {
        "$id": "https://example.com/shared-tree",
        "$dynamicAnchor": "node",
        "type": "object",
        "properties": {
          "name": {"type":"string"},
          "children": {"type":"array", "items":{"$dynamicRef":"#node"}}
        },
        "required":["name","children"]
      },
      "strict": {
        "$id":"https://example.com/shared-strict-tree",
        "$dynamicAnchor":"node",
        "$ref":"https://example.com/shared-tree",
        "properties":{"extra":{"type":"boolean"}},
        "required":["extra"],
        "unevaluatedProperties":false
      }
    }
    """##
  let trees = try SchemaGenerator().generateShared(
    document: .init(
      source: dynamic, retrievalURI: URL(string: "https://example.com/shared-dynamic.json")!),
    schemaPointers: ["/base", "/strict"], rootNames: ["BaseTree", "StrictTree"])
  try writeShared(trees, namespace: "SharedDynamicSchemas", output: output)
  try generateUntypedObjects(output: output)
  try generateUnknownPropertyModels(output: output)
  try generateParserFactoryModels(output: output)
  try generateUnionReferenceModels(output: output)
}

private func generateUntypedObjects(output: URL) throws {
  let model = ##"""
    {
      "description":"Object properties do not restrict the JSON kind.",
      "x-padding":"\##(String(repeating: "x", count: 5_000))",
      "x-literals":[1e400,1e-400,0.123456789012345678901,1.00,-0,true,null,
        "é","e\u0301","quote\"\u0301 slash\\\u0301 \r\n\t\u0000","\\(notInterpolation)\"###"],
      "properties":{
        "id":{"type":"string","minLength":1},
        "created":{"type":"integer"},
        "nickname":{"type":["string","null"]}
      },
      "required":["id","created"]
    }
    """##
  let source = """
    {
      "$defs":{"Model":\(model),"Mirror/~":{"$ref":"#/$defs/Model"}},
      "retrieve":{"$ref":"#/$defs/Model"},
      "list":{"type":"array","items":{"$ref":"#/$defs/Model"}},
      "strict":{"$ref":"#/$defs/Model","unevaluatedProperties":false},
      "escaped":{"$ref":"#/$defs/Mirror~1~0"}
    }
    """
  let generated = try SchemaGenerator().generateShared(
    document: .init(
      source: source, retrievalURI: URL(string: "https://example.com/untyped.json")!),
    schemaPointers: ["/retrieve", "/list", "/strict", "/escaped"],
    rootNames: ["Retrieve", "List", "Strict", "Escaped"])
  try writeShared(generated, namespace: "SharedUntypedSchemas", output: output)
  let strict = """
    {"$defs":{"Model":\(model)},"$ref":"#/$defs/Model","unevaluatedProperties":false}
    """
  for (source, namespace) in [
    (model, "LegacyUntypedSchema"), (strict, "LegacyUntypedStrictSchema"),
  ] {
    let generated = try SchemaGenerator().generate(source)
    let source = """
      import JSONSchema
      import JSONSchemaBuilder
      public enum \(namespace) {
        \(generated.declarations.joined(separator: "\n"))
        public static var schema: some JSONSchemaComponent<\(generated.outputType)> {
          \(generated.expression)
        }
      }
      """
    try source.write(
      to: output.appendingPathComponent(namespace + ".swift"), atomically: true, encoding: .utf8)
  }
}

func writeShared(
  _ generated: GeneratedSharedSchemas, namespace: String, output: URL
) throws {
  let roots = generated.roots.map { root in
    """
    public static var schema\(root.name): some JSONSchemaComponent<\(root.outputType)> {
      \(root.expression)
    }
    public static var encoder\(root.name): (\(root.outputType)) throws -> JSONValue {
      \(root.encodingExpression)
    }
    """
  }.joined(separator: "\n")
  let source = """
    import JSONSchema
    import JSONSchemaBuilder

    public enum \(namespace) {
      \(generated.declarations.joined(separator: "\n"))
      \(roots)
    }
    """
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  try source.write(
    to: output.appendingPathComponent(namespace + ".swift"), atomically: true, encoding: .utf8)
}
