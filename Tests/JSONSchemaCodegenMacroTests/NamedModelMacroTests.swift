import JSONSchemaCodegenMacros
import SwiftParser
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class NamedModelMacroTests: XCTestCase {
  private var macros: [String: Macro.Type] { ["Schema": SchemaMacro.self] }

  func testLiteralOptionsAndSingletonModel() {
    let text = expand(
      ##"@Schema(#"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#, output: .models, recursiveObjects: .valueTypes, typeNames: [:], caseNames: [:])"##
    )
    XCTAssertTrue(text.contains("struct Value"))
    XCTAssertTrue(text.contains("let name:"))
    XCTAssertTrue(text.contains("public static var schema: some JSONSchemaComponent<Value>"))
  }

  func testQualifiedOptions() {
    for qualifier in [
      "", "JSONSchemaCodegen.", "JSONSchemaCodegenCore.", "JSONSchemaCodegenConfiguration.",
    ] {
      let text = expand(
        #"@Schema("{\"type\":\"string\"}", output: \#(qualifier)SchemaOutputStyle.models, recursiveObjects: \#(qualifier)RecursiveObjectStrategy.valueTypes)"#
      )
      XCTAssertTrue(text.contains("typealias Value ="))
    }
  }

  func testLiteralTypeAndCaseOverrides() {
    let text = expand(
      ###"""
      @Schema(##"{"type":"object","properties":{"result":{"oneOf":[{"type":"string"},{"type":"integer"}]}},"required":["result"]}"##, output: .models, typeNames: ["#/properties/result": "Outcome"], caseNames: ["#/properties/result/oneOf/0": "text"])
      """###
    )
    XCTAssertTrue(text.contains("enum Outcome"))
    XCTAssertTrue(text.contains("case text("))
  }

  func testExplicitImmutableRecursion() {
    let text = expand(
      ###"""
      @Schema(##"{"type":"object","properties":{"next":{"$ref":"#"}}}"##, output: .models, recursiveObjects: .immutableClasses)
      """###
    )
    XCTAssertTrue(text.contains("final class Value"))
    XCTAssertFalse(text.contains("@unchecked Sendable"))
  }

  func testPublicStringEnumsAndCaseOverrides() {
    let text = expand(
      ##"""
      @Schema(#"{"type":"object","properties":{"status":{"type":"string","enum":["draft","in-progress"]}}}"#, output: .models, typeNames: ["#/properties/status": "State"], caseNames: ["#/properties/status/enum/1": "working"])
      """##)
    XCTAssertTrue(text.contains("public enum State: Swift.RawRepresentable"))
    XCTAssertTrue(text.contains("case draft"))
    XCTAssertTrue(text.contains("case working"))
    XCTAssertTrue(text.contains("public var rawValue: Swift.String"))
    XCTAssertTrue(text.contains("public init?(rawValue: Swift.String)"))
    XCTAssertTrue(text.contains(".compactMap"))
    XCTAssertFalse(text.contains("Codable"))
  }

  func testExplicitLegacyOptionsDoNotChangeExpansion() {
    XCTAssertEqual(
      expand(#"@Schema("{\"type\":\"string\"}")"#),
      expand(
        #"@Schema("{\"type\":\"string\"}", output: .tuples, recursiveObjects: .valueTypes, typeNames: [:], caseNames: [:])"#
      )
    )
  }

  func testUnknownAndRepeatedLabels() {
    assertDiagnostic(
      #"@Schema("{}", style: .models)"#,
      message: "@Schema has no option 'style'.", at: "style:"
    )
    assertDiagnostic(
      #"@Schema("{}", output: .models, output: .tuples)"#,
      message: "@Schema option 'output' may only be supplied once.", at: "output: .tuples"
    )
  }

  func testInvalidOutputCasesAndQualifications() {
    for value in [
      ".named", "style", #" "models" "#, "Other.models", "Other.SchemaOutputStyle.models",
      "SchemaOutputStyle.models()", "SchemaOutputStyle(rawValue: \"models\")!",
      "SchemaOutputStyle.self.models",
    ] {
      assertDiagnostic(
        #"@Schema("{}", output: \#(value))"#,
        message: "@Schema requires a literal SchemaOutputStyle case: .tuples or .models.",
        at: value.trimmingCharacters(in: .whitespaces)
      )
    }
    assertDiagnostic(
      #"@Schema("{}", recursiveObjects: .classes)"#,
      message:
        "@Schema requires a literal RecursiveObjectStrategy case: .valueTypes or .immutableClasses.",
      at: ".classes"
    )
  }

  func testDynamicOrNonDictionaryOverrides() {
    for value in ["names", "[:].merging(names) { $1 }", "[]", "nil"] {
      assertDiagnostic(
        #"@Schema("{}", typeNames: \#(value))"#,
        message: "@Schema 'typeNames' requires a literal dictionary of string selectors and names.",
        at: value
      )
    }
  }

  func testNonliteralOrInterpolatedOverrideElements() {
    for (value, location) in [
      (##"["#": name]"##, "name]"),
      (#"[selector: "Payload"]"#, "selector"),
      (##"["#": 42]"##, "42"),
      (##"["#": "\(name)"]"##, #""\(name)""#),
      (#"["\(selector)": "Payload"]"#, #""\(selector)""#),
    ] {
      assertDiagnostic(
        #"@Schema("{}", typeNames: \#(value))"#,
        message: "@Schema 'typeNames' keys and values must be non-interpolated string literals.",
        at: location
      )
    }
  }

  func testDuplicateSelectorsUseDecodedLiteralValues() {
    assertDiagnostic(
      ##"@Schema("{}", caseNames: ["#/oneOf/0": "first", "\u{23}/oneOf/0": "second"])"##,
      message: "@Schema 'caseNames' contains duplicate selector '#/oneOf/0'.",
      at: #""\u{23}/oneOf/0""#
    )
  }

  func testMalformedOverrideNamesAndEmptySelectors() {
    for name in ["", "two words", "Bad.Name", "`class`", "class", "1Name", "_", "name()"] {
      assertDiagnostic(
        ##"@Schema("{}", typeNames: ["#": "\##(name)"])"##,
        message:
          "@Schema 'typeNames' override '\(name)' must be an unquoted ASCII Swift identifier.",
        at: "\"\(name)\""
      )
    }
    assertDiagnostic(
      #"@Schema("{}", caseNames: ["": "ready"])"#,
      message: "@Schema 'caseNames' selectors must not be empty; use '#' for the root.",
      at: #""": "ready""#
    )
  }

  private func expand(
    _ attribute: String, file: StaticString = #filePath, line: UInt = #line
  ) -> String {
    let context = BasicMacroExpansionContext()
    let parsed = Parser.parse(source: "\(attribute)\npublic enum Example {}")
    let expanded = parsed.expand(macros: macros, contextGenerator: { _ in context })
    XCTAssertTrue(
      context.diagnostics.isEmpty, "\(context.diagnostics.map(\.message))", file: file, line: line
    )
    return expanded.description.replacingOccurrences(of: "`", with: "")
  }

  private func assertDiagnostic(
    _ attribute: String, message: String, at location: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let range = attribute.range(of: location, options: .backwards)!
    let column = attribute.distance(from: attribute.startIndex, to: range.lowerBound) + 1
    assertMacroExpansion(
      "\(attribute)\nenum Example {}",
      expandedSource: "enum Example {}",
      diagnostics: [DiagnosticSpec(message: message, line: 1, column: column)],
      macros: macros, file: file, line: line
    )
  }
}
