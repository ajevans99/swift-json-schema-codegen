import CustomDump
import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import Testing

@testable import JSONSchemaCodegenCore

struct SchemaPropertyNamingTests {
  @Test func existingIdentifiersAreProtectedBeforeNormalizingOtherKeys() {
    let names = [
      "$id", "id", "$id!", "id_2", "a-b", "a_b", "a b", "a_b_2",
      "", "-", "_", "property", "property_2", "日本語", "_123", "123", "`class`", "class",
    ]
    expectNoDifference(
      SchemaPropertyNames.labels(for: names),
      [
        "id_3", "id", "id_4", "id_2", "a_b_3", "a_b", "a_b_4", "a_b_2",
        "property_3", "property_4", "property_5", "property", "property_2", "property_6",
        "_123", "_123_2", "class_2", "class",
      ])
  }

  @Test(arguments: [
    ("$id", "id"),
    ("a/b~c", "a_b_c"),
    ("a---b", "a_b"),
    ("a\nb", "a_b"),
    ("a b", "a_b"),
    ("1name", "_1name"),
    ("naïve", "na_ve"),
    ("💛", "property"),
    ("", "property"),
    ("_", "property"),
    ("---", "property"),
    ("`class`", "class"),
    ("__value", "__value"),
    ("value_", "value_"),
    ("A_Z09", "A_Z09"),
  ])
  func arbitraryNamesBecomeASCIILabels(name: String, label: String) {
    expectNoDifference(SchemaPropertyNames.labels(for: [name]), [label])
  }

  @Test func denseCollisionsRemainUniqueAndDeterministic() {
    let names =
      (0...255).compactMap(UnicodeScalar.init).map(String.init)
      + ["", "💛", "日本語", "property", "property_2", "property_100", "_1", "_1_2"]
    let labels = SchemaPropertyNames.labels(for: names)
    expectNoDifference(labels.count, names.count)
    expectNoDifference(Set(labels).count, names.count)
    expectNoDifference(SchemaPropertyNames.labels(for: names), labels)
    for label in labels {
      #expect(label != "_")
      #expect(label.wholeMatch(of: /[a-zA-Z_][a-zA-Z_0-9]*/) != nil)
    }
  }

  @Test func generatedTypesKeepOrderAndJSONKeys() throws {
    let source = #"""
      {
        "type":"object",
        "properties":{
          "$id":{"type":"string"},
          "id":{"type":"integer"},
          "a/b~c":{"type":"boolean"},
          "_":{"type":"number"},
          "":{"type":"string"},
          "日本語":{"type":"string"}
        },
        "required":["$id","_",""]
      }
      """#
    let generated = try SchemaGenerator().generate(source)
    expectNoDifference(
      generated.outputType,
      "(`id_2`: String, `id`: Int?, `a_b_c`: Bool?, `property`: Double, `property_2`: String, `property_3`: String?)"
    )
    #expect(generated.expression.contains("(id_2: $0.0, id: $0.1, a_b_c: $0.2"))
    let visitor = PropertyKeyVisitor(viewMode: .sourceAccurate)
    visitor.walk(Parser.parse(source: generated.expression))
    expectNoDifference(visitor.keys, ["$id", "id", "a/b~c", "_", "", "日本語"])
    expectNoDifference(try SchemaGenerator().generate(source), generated)
  }

  @Test func nestedObjectsAllocateLabelsIndependently() throws {
    let generated = try SchemaGenerator().generate(
      #"""
      {"type":"object","properties":{
        "$id":{"type":"string"},
        "id":{"type":"array","items":{
          "type":"object","properties":{"$id":{"type":"integer"},"other":{"type":"boolean"}},
          "required":["$id","other"]
        }}
      },"required":["$id","id"]}
      """#)
    expectNoDifference(
      generated.outputType, "(`id_2`: String, `id`: [(`id`: Int, `other`: Bool)])")
  }

  @Test(arguments: ["", "_", "-", "日本語", "\"\\(fatalError())\n\0", "\"\u{301}"])
  func jsonKeyLiteralsPreserveOriginalScalars(name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "type": "object",
      "properties": [name: ["type": "string"], "unchanged": ["type": "integer"]],
    ])
    let generated = try SchemaGenerator().generate(String(decoding: data, as: UTF8.self))
    let visitor = PropertyKeyVisitor(viewMode: .sourceAccurate)
    visitor.walk(Parser.parse(source: generated.expression))
    let original = try #require(visitor.keys.first { $0 != "unchanged" })
    expectNoDifference(original.unicodeScalars.map(\.value), name.unicodeScalars.map(\.value))
  }

  @Test(arguments: [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func",
    "import", "init", "inout", "internal", "let", "open", "operator", "private",
    "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias",
    "var", "break", "case", "catch", "continue", "default", "defer", "do", "else",
    "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
    "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self",
    "super", "throws", "true", "try",
  ])
  func keywordLabelsUseExistingSyntaxEscaping(name: String) throws {
    expectNoDifference(SchemaPropertyNames.labels(for: [name]), [name])
    let generated = try SchemaGenerator().generate(
      """
      {"type":"object","properties":{"\(name)":{"type":"integer"},"other":{"type":"boolean"}}}
      """)
    expectNoDifference(generated.outputType, "(`\(name)`: Int?, `other`: Bool?)")
    let file = Parser.parse(
      source: """
        let schema: some JSONSchemaComponent<\(generated.outputType)> = \(generated.expression)
        """)
    #expect(!file.hasError)
    #expect(ParseDiagnosticsGenerator.diagnostics(for: file).isEmpty)
  }
}

private final class PropertyKeyVisitor: SyntaxVisitor {
  var keys: [String] = []

  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    if node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "JSONProperty",
      let literal = node.arguments.first?.expression.as(StringLiteralExprSyntax.self),
      let value = literal.representedLiteralValue
    {
      keys.append(value)
    }
    return .visitChildren
  }
}
