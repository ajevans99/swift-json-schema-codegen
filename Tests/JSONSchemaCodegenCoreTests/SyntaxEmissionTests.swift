import CustomDump
import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import Testing

@testable import JSONSchemaCodegenCore

struct SyntaxEmissionTests {
  @Test(arguments: [
    ("", "property"), ("_", "property"), ("1name", "_1name"), ("a-b", "a_b"),
    ("a b", "a_b"), ("`class`", "class"), ("naïve", "na_ve"), ("a\nb", "a_b"),
    ("a/b~c", "a_b_c"),
  ])
  func arbitraryPropertyKeysProduceValidIdentifierNodes(name: String, label: String) throws {
    let json = try JSONSerialization.data(
      withJSONObject: [
        "type": "object",
        "properties": [name: ["type": "string"], "zzSentinel": ["type": "boolean"]],
      ],
      options: .sortedKeys
    )
    let generated = try SchemaGenerator().generate(String(decoding: json, as: UTF8.self))
    expectNoDifference(generated.outputType, "(`\(label)`: String?, `zzSentinel`: Bool?)")
    let file = Parser.parse(
      source: """
        typealias Output = \(generated.outputType)
        let schema = \(generated.expression)
        """)
    #expect(!file.hasError)
    #expect(ParseDiagnosticsGenerator.diagnostics(for: file).isEmpty)
  }

  @Test(arguments: [
    "", "plain ASCII", "\"quoted\"", "\\(fatalError())", "\\#(value)\\##(value)",
    "\"# \"## \"### \\###(", "\0\r\n\t\u{7f}\u{85}\u{2028}\u{2029}",
    "café", "cafe\u{301}", "👨‍👩‍👧‍👦", "\"\u{301}", "\\\u{301}", "\"#\u{301}\\##\u{301}",
    String(String.UnicodeScalarView((0...31).compactMap(UnicodeScalar.init))),
  ])
  func stringLiteralsPreserveEveryScalar(value: String) throws {
    let json = try JSONSerialization.data(withJSONObject: ["type": "string", "description": value])
    let generated = try SchemaGenerator().generate(String(decoding: json, as: UTF8.self))
    var parser = Parser(generated.expression)
    let call = try #require(ExprSyntax.parse(from: &parser).as(FunctionCallExprSyntax.self))
    let literal = try #require(call.arguments.first?.expression.as(StringLiteralExprSyntax.self))
    #expect(!literal.hasError)
    #expect(literal.segments.allSatisfy { $0.is(StringSegmentSyntax.self) })
    let represented = try #require(literal.representedLiteralValue)
    expectNoDifference(
      represented.unicodeScalars.map(\.value), value.unicodeScalars.map(\.value)
    )
  }

  @Test(arguments: [
    "true", "false", "{}",
    #"{"type":["string","null"],"enum":["x",null],"description":"optional"}"#,
    #"{"type":"object","properties":{"z":{"type":"integer"},"class":{"type":["string","null"]}},"required":["z"]}"#,
    #"{"type":"array","items":{"type":"array","items":false}}"#,
    #"{"oneOf":[true,false]}"#,
    #"{"anyOf":[{"type":"array","items":true},{"type":"array","items":false}]}"#,
    #"{"oneOf":[{"type":"string"},{"type":"integer"}]}"#,
    #"{"allOf":[{"type":"string","minLength":1},{"maxLength":5}]}"#,
    #"{"type":"string","default":{"quote\"":{"array":[null,true,-42,-0.5,{}]}}}"#,
  ])
  func completeOutputReparsesDeterministically(source: String) throws {
    let generated = try SchemaGenerator().generate(source)
    expectNoDifference(try SchemaGenerator().generate(source), generated)
    let text = """
      enum Generated {
      \(generated.declarations.joined(separator: "\n"))
      static var schema: some JSONSchemaComponent<\(generated.outputType)> {
      \(generated.expression)
      }
      }
      """
    var parser = Parser(text, maximumNestingLevel: 256)
    let file = SourceFileSyntax.parse(from: &parser)
    #expect(!file.hasError)
    #expect(ParseDiagnosticsGenerator.diagnostics(for: file).isEmpty)
  }

  @Test func tuplesAndMappingAreStructuredAndOrdered() throws {
    let fields: [SchemaOutput.Field] = [
      .init(name: "z", type: "Int"),
      .init(name: "inout", type: .optional(.optional("String"))),
    ]
    let type = try #require(SchemaOutput.tuple(fields).syntax.as(TupleTypeSyntax.self))
    expectNoDifference(type.elements.map { $0.firstName?.text }, ["`z`", "`inout`"])
    let nested = try #require(type.elements.last?.type.as(OptionalTypeSyntax.self))
    #expect(nested.wrappedType.is(OptionalTypeSyntax.self))

    let mapped = SchemaSyntax.tupleMap(
      SchemaSyntax.call(SchemaSyntax.reference("JSONObject")), fields: fields)
    let call = try #require(mapped.as(FunctionCallExprSyntax.self))
    let tuple = try #require(call.trailingClosure?.statements.first?.item.as(TupleExprSyntax.self))
    expectNoDifference(tuple.elements.map { $0.label?.text }, ["z", "`inout`"])
    expectNoDifference(
      tuple.elements.map { SchemaSyntax.formatted($0.expression).trimmedDescription },
      ["$0.0", "$0.1"])
  }

  @Test func enumPayloadsAndSendableClosureSignaturesAreNodes() throws {
    let declaration = try #require(
      SchemaSyntax.unionDeclaration("Union1", outputs: ["String", .array("Int")]).as(
        EnumDeclSyntax.self)
    )
    expectNoDifference(declaration.modifiers.map(\.name.text), ["public"])
    expectNoDifference(
      declaration.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription, "Sendable")
    let cases = declaration.memberBlock.members.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
    expectNoDifference(cases.compactMap { $0.elements.first?.name.text }, ["option1", "option2"])
    #expect(
      cases.last?.elements.first?.parameterClause?.parameters.first?.type.is(ArrayTypeSyntax.self)
        == true)

    let mapped = SchemaSyntax.unionMap(
      SchemaSyntax.call(SchemaSyntax.reference("JSONString")),
      input: SchemaOutput.named("String").syntax, output: SchemaOutput.named("Union1").syntax,
      index: 0
    )
    let signature = try #require(mapped.as(FunctionCallExprSyntax.self)?.trailingClosure?.signature)
    #expect(
      signature.attributes.first?.as(AttributeSyntax.self)?.attributeName.trimmedDescription
        == "Sendable")
    #expect(signature.returnClause?.type.is(IdentifierTypeSyntax.self) == true)
    guard case .parameterClause(let parameters) = signature.parameterClause else {
      Issue.record("Expected an explicitly typed closure parameter")
      return
    }
    expectNoDifference(parameters.parameters.first?.type?.trimmedDescription, "String")
  }

  @Test func malformedBuilderOutputSurfacesLocatedCompilerDiagnostics() throws {
    let file = Parser.parse(source: "let value =")
    let uri = URL(string: "https://example.com/schema.json")!
    do {
      try SchemaSyntax.validate(file, pointer: "/properties/name", documentURI: uri)
      Issue.record("Missing expression syntax must produce diagnostics")
    } catch let error as SchemaGenerationError {
      expectNoDifference(error.pointer, "/properties/name")
      expectNoDifference(error.documentURI, uri)
      #expect(error.message.contains("<generated>:1:"))
      #expect(error.message.contains("error:"))
    }
  }

  @Test func roundTripDetectsLexicallyMalformedIdentifierTokens() {
    let expression = SchemaSyntax.reference("not an identifier")
    #expect(!expression.hasError)
    let parsed = Parser.parse(source: expression.description)
    #expect(parsed.hasError)
    #expect(throws: SchemaGenerationError.self) { try SchemaSyntax.validate(parsed) }
  }

  @Test func missingTokensAreNotSilentlyFormattedIntoValidOutput() {
    let file = Parser.parse(source: "let value =")
    #expect(throws: SchemaGenerationError.self) { try SchemaSyntax.validate(file) }
  }
}
