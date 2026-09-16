import CustomDump
import Foundation
import JSONSchemaCodegenCore
import Testing

@Suite
struct UnionReferenceGenerationTests {
  @Test(arguments: [false, true])
  func annotationsShareUnionPayloadsWhileTypedRefinementsStayDistinct(preserving: Bool) throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../NamedModels/Fixtures/union-reference-annotations.json")
    let document = SchemaDocument(
      source: try String(contentsOf: fixture, encoding: .utf8),
      retrievalURI: URL(string: "https://example.com/union.json")!)
    let entries = [
      ("first", "First"), ("second", "Second"), ("plain", "Plain"),
      ("nullableFirst", "NullableFirst"), ("nullableSecond", "NullableSecond"),
      ("specializedFirst", "SpecializedFirst"), ("specializedSecond", "SpecializedSecond"),
      ("strict", "Strict"),
    ]
    let generator = SchemaGenerator(
      options: .init(unknownProperties: preserving ? .preserve : .discard))
    let forward = try generator.generateShared(
      document: document, schemaPointers: entries.map { "/properties/" + $0.0 },
      rootNames: entries.map(\.1))
    let reverse = try generator.generateShared(
      document: document, schemaPointers: entries.reversed().map { "/properties/" + $0.0 },
      rootNames: entries.reversed().map(\.1))
    for result in [forward, reverse] {
      let declarations = result.declarations.joined(separator: "\n")
        .replacingOccurrences(of: "`", with: "")
      for name in ["First", "Second", "Plain", "Strict"] {
        #expect(declarations.contains("typealias \(name) = Caller\n"))
      }
      for name in ["NullableFirst", "NullableSecond"] {
        #expect(declarations.contains("typealias \(name) = Caller?"))
      }
      for name in ["SpecializedFirst", "SpecializedSecond"] {
        #expect(declarations.contains("typealias \(name) = Specialized\n"))
      }
      #expect(declarations.contains("case direct(Direct)"))
      #expect(declarations.contains("case program(Program)"))
      expectNoDifference(declarations.components(separatedBy: "public struct Direct:").count, 2)
      expectNoDifference(declarations.components(separatedBy: "public struct Program:").count, 2)
      #expect(declarations.contains("let extra: Int\n"))
    }
    let models: (GeneratedSharedSchemas) -> [String] = { result in
      result.declarations.filter {
        $0.hasPrefix("public struct ") || $0.hasPrefix("public enum ")
          || $0.hasPrefix("public indirect enum ")
      }
    }
    expectNoDifference(models(forward), models(reverse))
  }
}
