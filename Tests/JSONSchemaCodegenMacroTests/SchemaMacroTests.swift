import JSONSchemaCodegenMacros
import SwiftParser
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class SchemaMacroTests: XCTestCase {
  private var macros: [String: Macro.Type] { ["Schema": SchemaMacro.self] }

  func testPrimitive() {
    assertExpansion(
      #"@Schema("{\"type\":\"string\"}")"#,
      expression: "JSONString()",
      output: "String"
    )
  }

  func testRawString() {
    assertExpansion(
      ##"@Schema(#"{"type":"string","pattern":"^\\d+$"}"#)"##,
      expression: #"""
        JSONString()
        .pattern("^\\d+$")
        """#,
      output: "String"
    )
  }

  func testMultilineIndentationAndLineContinuation() {
    assertExpansion(
      #"""
        @Schema("""
          {
            "type": \
            "integer"
          }
          """)
        """#,
      expression: "JSONInteger()",
      output: "Int"
    )
  }

  func testSwiftUnicodeEscape() {
    assertExpansion(
      #"@Schema("{\"type\":\"\u{73}tring\"}")"#,
      expression: "JSONString()",
      output: "String"
    )
  }

  func testRawMultilineLiteral() {
    assertExpansion(
      ##"""
        @Schema(#"""
          {"type":"array","items":{"type":"boolean"}}
          """#)
        """##,
      expression: """
        JSONArray {
          JSONBoolean()
        }
        """,
      output: "[Bool]"
    )
  }

  func testSingletonObjectIsUnwrapped() {
    assertExpansion(
      ##"@Schema(#"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#)"##,
      expression: """
        JSONObject {
          JSONProperty(key: "name") {
            JSONString()
          }
          .required()
        }
        """,
      output: "String"
    )
  }

  func testLabeledTupleOutput() {
    assertExpansion(
      ##"@Schema(#"{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name"]}"#)"##,
      expression: """
        JSONObject {
          JSONProperty(key: "name") {
            JSONString()
          }
          .required()
          JSONProperty(key: "age") {
            JSONInteger()
          }
        }
        .map {
            (name: $0.0, age: $0.1)
        }
        """,
      output: "(`name`: String, `age`: Int?)"
    )
  }

  func testEmptyObject() {
    assertExpansion(
      ##"@Schema(#"{"type":"object"}"#)"##,
      expression: "JSONObject()",
      output: "Void"
    )
  }

  func testDynamicOutputUsesJSONValue() {
    assertExpansion(#"@Schema("{}")"#, expression: "JSONAnyValue()", output: "JSONValue")
  }

  func testLocalReferenceExpansion() {
    assertExpansion(
      ###"@Schema(##"{"$defs":{"count":{"type":"integer"}},"$ref":"#/$defs/count"}"##)"###,
      expression: "JSONInteger()",
      output: "Int"
    )
  }

  func testGeneratedUnionMembers() {
    let source = ##"""
      @Schema(#"{"oneOf":[{"type":"string"},{"type":"boolean"}]}"#)
      public enum Token {}
      """##
    // Runtime integration covers the full expansion; this checks the declaration
    // contract independently of formatting in supporting generic helpers.
    let context = BasicMacroExpansionContext()
    let parsed = Parser.parse(source: source)
    let expanded = parsed.expand(macros: macros, contextGenerator: { _ in context })
    let text = expanded.description
    XCTAssertTrue(text.contains("public enum Union1: Sendable"))
    XCTAssertTrue(text.contains("case option1(String)"))
    XCTAssertTrue(text.contains("case option2(Bool)"))
    XCTAssertTrue(text.contains("public static var schema: some JSONSchemaComponent<Union1>"))
    XCTAssertTrue(context.diagnostics.isEmpty)
  }

  func testReferencedDefinitionDiagnostic() {
    assertDiagnostic(
      ###"@Schema(##"{"$defs":{"color":{"type":"string","minLength":-1}},"$ref":"#/$defs/color"}"##)"###,
      message: "#/$defs/color/minLength: Expected a nonnegative integer representable by Swift.Int."
    )
  }

  func testRecursiveReferenceDiagnostic() {
    assertDiagnostic(
      ###"@Schema(##"{"$ref":"#"}"##)"###,
      message: "#/$ref: Recursive reference cannot be represented by a finite Swift tuple: # -> #."
    )
  }

  func testPublicAccess() {
    assertExpansion(
      ##"@Schema(#"{"type":"string"}"#)"##,
      expression: "JSONString()",
      output: "String",
      access: "public "
    )
  }

  func testPackageAccess() {
    assertExpansion(
      ##"@Schema(#"{"type":"string"}"#)"##,
      expression: "JSONString()",
      output: "String",
      access: "package "
    )
  }

  func testNonliteralDiagnostic() {
    assertDiagnostic(
      "@Schema(json)",
      message: "@Schema requires an inline string literal; runtime expressions are not supported."
    )
  }

  func testConcatenationDiagnostic() {
    assertDiagnostic(
      #"@Schema("{" + "}")"#,
      message: "@Schema requires an inline string literal; runtime expressions are not supported."
    )
  }

  func testInterpolationDiagnostic() {
    assertDiagnostic(
      #"@Schema("{\"type\":\"\(kind)\"}")"#,
      message: "@Schema does not support string interpolation; use a complete JSON Schema literal."
    )
  }

  func testRawInterpolationDiagnostic() {
    assertDiagnostic(
      ##"@Schema(#"{"type":"\#(kind)"}"#)"##,
      message: "@Schema does not support string interpolation; use a complete JSON Schema literal."
    )
  }

  func testArgumentCountDiagnostic() {
    for attribute in ["@Schema()", #"@Schema("{}", "{}")"#, #"@Schema(json: "{}")"#] {
      assertDiagnostic(
        attribute,
        message: "@Schema requires exactly one unlabeled string literal.",
        column: 1
      )
    }
  }

  func testSchemaDiagnosticIncludesJSONPointer() {
    assertDiagnostic(
      ##"@Schema(#"{"type":"object","properties":{"value":{"type":"string","oneOf":[]}}}"#)"##,
      message: "#/properties/value/oneOf: 'oneOf' must be a nonempty array of schemas."
    )
  }

  func testNonSchemaJSONDiagnostic() {
    assertDiagnostic(#"@Schema("42")"#, message: "#: Expected a schema object or boolean.")
  }

  func testMalformedJSONDiagnosticIncludesSourceLocation() {
    assertDiagnostic(
      #"@Schema("{\n  invalid}")"#,
      message: "#: Invalid JSON at line 2, column 3: Expected string key in object"
    )
  }

  func testUnrepresentablePropertyDiagnosticEscapesJSONPointer() {
    assertDiagnostic(
      ##"@Schema(#"{"type":"object","properties":{"a/b~c":{"type":"string"}}}"#)"##,
      message: "#/properties/a~1b~0c: Property name 'a/b~c' cannot be represented as a Swift tuple label; use an ASCII identifier."
    )
  }

  func testNonEnumDiagnostic() {
    for declaration in ["struct Example {}", "class Example {}", "actor Example {}"] {
      assertDiagnostic(
        #"@Schema("{}")"#,
        declaration: declaration,
        message: "@Schema can only be attached to an empty namespace enum.",
        column: 1
      )
    }
  }

  func testGenericEnumDiagnostic() {
    assertDiagnostic(
      #"@Schema("{}")"#,
      declaration: "enum Example<Value> {}",
      message: "@Schema requires a non-generic enum outside generic contexts.",
      column: 1
    )
  }

  func testEnclosingGenericContextDiagnostic() {
    assertMacroExpansion(
      """
      struct Container<Value> {
          @Schema("{}")
          enum Example {}
      }
      """,
      expandedSource: """
        struct Container<Value> {
            enum Example {}
        }
        """,
      diagnostics: [
        DiagnosticSpec(
          message: "@Schema requires a non-generic enum outside generic contexts.",
          line: 2,
          column: 5
        )
      ],
      macros: macros
    )
  }

  func testNonemptyEnumDiagnostic() {
    assertDiagnostic(
      #"@Schema("{}")"#,
      declaration: "enum Example {\n    case value\n}",
      message: "@Schema requires an empty namespace enum; remove its existing members.",
      column: 1
    )
  }

  func testSchemaNameConflictDiagnostic() {
    for member in [
      "static var schema: Int { 1 }",
      "static func schema() {}",
      "case schema",
      "typealias schema = Int",
      "static let `schema` = 1",
    ] {
      assertDiagnostic(
        #"@Schema("{}")"#,
        declaration: "enum Example {\n    \(member)\n}",
        message: "@Schema cannot generate 'schema' because the enum already declares that name.",
        column: 1
      )
    }
  }

  func testDuplicateAttributeDiagnostic() {
    assertMacroExpansion(
      """
      @Schema("{}")
      @Schema("{}")
      enum Example {}
      """,
      expandedSource: "enum Example {}",
      diagnostics: [
        DiagnosticSpec(
          message: "@Schema may only be applied once to an enum.",
          line: 1,
          column: 1
        ),
        DiagnosticSpec(
          message: "@Schema may only be applied once to an enum.",
          line: 2,
          column: 1
        ),
      ],
      macros: macros
    )
  }

  private func assertExpansion(
    _ attribute: String,
    expression: String,
    output: String,
    access: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let body = expression.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "        \($0)" }.joined(separator: "\n")
    assertMacroExpansion(
      "\(attribute)\n\(access)enum Example {}",
      expandedSource: """
        \(access)enum Example {

            \(access)static var schema: some JSONSchemaComponent<\(output)> {
        \(body)
            }
        }
        """,
      macros: macros,
      file: file,
      line: line
    )
  }

  private func assertDiagnostic(
    _ attribute: String,
    declaration: String = "enum Example {}",
    message: String,
    column: Int = 9,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    assertMacroExpansion(
      "\(attribute)\n\(declaration)",
      expandedSource: declaration,
      diagnostics: [DiagnosticSpec(message: message, line: 1, column: column)],
      macros: macros,
      file: file,
      line: line
    )
  }
}
