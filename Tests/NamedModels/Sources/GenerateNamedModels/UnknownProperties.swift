import Foundation
import JSONSchemaCodegenCore

func generateUnknownPropertyModels(output: URL) throws {
  let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures").standardizedFileURL
  let source = try String(
    contentsOf: fixtures.appendingPathComponent("unknown-properties.json"),
    encoding: .utf8)
  let names = [
    "Leaf", "Nested", "BooleanExtras", "PatternTyped", "TypedOnly", "Composed", "Strict",
    "Forbidden", "Union", "ClosedReference", "ClosedComposed", "EmptyClosed",
    "PatternClosed", "PatternClosedReference", "PatternClosedComposed", "PatternOnlyClosed",
    "PatternRestricted",
  ]
  let pointers = [
    "/$defs/Leaf", "/nested", "/booleanExtras", "/patternTyped", "/typedOnly", "/composed",
    "/strict", "/forbidden", "/union", "/closedReference", "/closedComposed", "/emptyClosed",
    "/patternClosed", "/patternClosedReference", "/patternClosedComposed", "/patternOnlyClosed",
    "/patternRestricted",
  ]
  for (namespace, strategy) in [
    ("PreservedUnknownSchemas", UnknownPropertyStrategy.preserve),
    ("DefaultUnknownSchemas", .discard),
  ] {
    let generated = try SchemaGenerator(options: .init(unknownProperties: strategy)).generateShared(
      document: .init(
        source: source, retrievalURI: URL(string: "https://example.com/unknown.json")!),
      schemaPointers: pointers, rootNames: names)
    try writeShared(generated, namespace: namespace, output: output)
  }
}
