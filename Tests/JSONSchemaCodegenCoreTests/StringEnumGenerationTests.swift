import CustomDump
import Foundation
import Testing

@testable import JSONSchemaCodegenCore

struct StringEnumGenerationTests {
  private func generate(_ source: String, names: SchemaNameOverrides = .init()) throws
    -> GeneratedSchema
  {
    try SchemaGenerator(options: .init(output: .models, names: names)).generate(source)
  }

  private func declarations(_ schema: GeneratedSchema) -> String {
    schema.declarations.joined(separator: "\n").replacingOccurrences(of: "`", with: "")
  }

  private func cases(_ schema: GeneratedSchema) -> [String] {
    declarations(schema).components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { $0.hasPrefix("case ") && !$0.hasPrefix("case .") }
  }

  @Test func rootEmitsExactRawRepresentableEnumAndFallibleMap() throws {
    let schema = try generate(#"{"type":"string","enum":["draft","in-progress","done"]}"#)
    expectNoDifference(schema.outputType, "Value")
    expectNoDifference(cases(schema), ["case draft", "case inProgress", "case done"])
    let text = declarations(schema)
    #expect(text.contains("enum Value: Swift.RawRepresentable, Swift.Sendable, Swift.Hashable"))
    #expect(text.contains("public init?(rawValue: Swift.String)"))
    #expect(text.contains("public var rawValue: Swift.String"))
    #expect(text.contains("unicodeScalars.elementsEqual"))
    #expect(text.contains("public static func =="))
    #expect(text.contains("hasher.combine(Swift.Array(rawValue.unicodeScalars))"))
    #expect(schema.expression.contains(".compactMap"))
    #expect(!schema.expression.contains("!"))
    #expect(!text.contains("Codable"))
  }

  @Test func tupleOutputIsUnchanged() throws {
    let source = #"{"type":"string","enum":["draft","in-progress","done"]}"#
    let legacy = try SchemaGenerator().generate(source)
    expectNoDifference(legacy.outputType, "String")
    expectNoDifference(legacy.declarations, [])
    expectNoDifference(
      legacy.expression,
      """
      JSONComponents.Enum(upstream: JSONString(), cases: [.string("draft"), .string("in-progress"), .string("done")])
      """)
  }

  @Test func finiteApplicabilityIsBounded() throws {
    for source in [
      #"{"enum":["draft","done"]}"#,
      #"{"type":["string"],"enum":["draft"]}"#,
      #"{"allOf":[{"enum":["draft","done"]},{"maxLength":5}]}"#,
      #"{"allOf":[{"type":"string"},{"enum":["draft"]}]}"#,
    ] {
      #expect(declarations(try generate(source)).contains("enum Value: Swift.RawRepresentable"))
    }
    for (source, output) in [
      (#"{"enum":[]}"#, "JSONValue"),
      (#"{"type":"string","enum":[]}"#, "String"),
      (#"{"enum":[null]}"#, "JSONValue"),
      (#"{"enum":["draft",1]}"#, "JSONValue"),
      (#"{"type":"string","enum":["draft",1]}"#, "String"),
      (#"{"type":"string","const":"draft"}"#, "String"),
      (#"{"const":"draft"}"#, "JSONValue"),
      (#"{"type":"string"}"#, "String"),
      (#"{"if":{"enum":["draft"]},"then":{"enum":["done"]}}"#, "JSONValue"),
      (#"{"not":{"enum":["draft"]}}"#, "JSONValue"),
    ] {
      let schema = try generate(source)
      #expect(declarations(schema).contains("typealias Value = \(output)"))
      expectNoDifference(cases(schema), [])
    }
  }

  @Test func nullabilityAndContainerRolesArePreserved() throws {
    for source in [
      #"{"enum":["draft",null]}"#,
      #"{"type":["string","null"],"enum":["draft",null]}"#,
      #"{"anyOf":[{"type":"string","enum":["draft"]},{"type":"null"}]}"#,
    ] {
      #expect(declarations(try generate(source)).contains("typealias Value = StringValue?"))
    }
    #expect(
      declarations(try generate(#"{"type":"array","items":{"enum":["draft"]}}"#))
        .contains("typealias Value = [Item]"))
    #expect(
      declarations(try generate(#"{"type":"object","additionalProperties":{"enum":["draft"]}}"#))
        .contains("typealias Value = [String: Entry]"))
    #expect(
      declarations(
        try generate(#"{"type":"object","properties":{"Alternative":{"enum":["draft"]}}}"#)
      )
      .contains("let Alternative: Alternative?"))
  }

  @Test func duplicateValuesKeepAllSelectorsButOneCase() throws {
    let source = #"{"enum":["draft","draft","done"]}"#
    let schema = try generate(source, names: .init(caseNames: ["#/enum/1": "initial"]))
    expectNoDifference(cases(schema), ["case initial", "case done"])
    #expect(schema.expression.contains(#".string("draft"), .string("draft")"#))
    #expect(throws: SchemaGenerationError.self) {
      try generate(source, names: .init(caseNames: ["#/enum/0": "one", "#/enum/1": "two"]))
    }
  }

  @Test func normalizationCollisionsUseValueIdentityNotOrder() throws {
    let first = try generate(#"{"enum":["a-b","a_b","","123","class","rawValue","é","e\u0301"]}"#)
    let reordered = try generate(
      #"{"enum":["e\u0301","é","rawValue","class","123","","a_b","a-b"]}"#)
    expectNoDifference(Set(cases(first)), Set(cases(reordered)))
    expectNoDifference(cases(first).count, 8)
    #expect(cases(first).contains("case alternative123"))
    #expect(cases(first).contains("case class"))
    #expect(cases(first).contains(where: { $0.hasPrefix("case aB_") }))
    #expect(cases(first).contains(where: { $0.hasPrefix("case rawValue_") }))
    #expect(declarations(first).contains("\"e\u{301}\""))
    expectNoDifference(try generate(#"{"enum":["é","e\u0301","é"]}"#).declarations.count, 2)
    // Type inference retains the original no-type validation definition.
    expectNoDifference(cases(try generate(#"{"enum":["é","e\u0301","é"]}"#)).count, 2)
  }

  @Test func invalidCaseAndTypeOverridesAreDiagnosed() throws {
    for name in ["rawValue", "RawValue", "hash", "hashValue", "Self", "bad-name"] {
      #expect(throws: SchemaGenerationError.self) {
        try generate(#"{"enum":["draft"]}"#, names: .init(caseNames: ["#/enum/0": name]))
      }
    }
    for selector in ["#/enum/2", "#/const", "#/enum"] {
      #expect(throws: SchemaGenerationError.self) {
        try generate(#"{"enum":["draft"]}"#, names: .init(caseNames: [selector: "draft"]))
      }
    }
    #expect(throws: SchemaGenerationError.self) {
      try generate(#"{"enum":["draft"]}"#, names: .init(typeNames: ["#": "Status"]))
    }
  }

  @Test func referencesShareDefinitionsButEnumRefinementsSpecialize() throws {
    let schema = try generate(
      ##"""
      {"type":"object","$defs":{"Status":{"type":"string","enum":["draft","done"]},"Other":{"type":"string","enum":["draft","done"]},"Text":{"type":"string"}},
       "properties":{"first":{"$ref":"#/$defs/Status"},"second":{"$ref":"#/$defs/Status","description":"Second"},"other":{"$ref":"#/$defs/Other"},"refined":{"$ref":"#/$defs/Status","enum":["done"]},"bounded":{"$ref":"#/$defs/Text","enum":["draft"]},"constant":{"$ref":"#/$defs/Status","const":"draft"}}}
      """##)
    let text = declarations(schema)
    for property in ["first", "second", "constant"] {
      #expect(text.contains("let \(property): Status?"))
    }
    #expect(text.contains("let other: Other?"))
    #expect(text.contains("let refined: Refined?"))
    #expect(text.contains("let bounded: Bounded?"))
    expectNoDifference(text.components(separatedBy: "enum Status:").count, 2)
  }

  @Test func mixedEnumRefinementsDoNotSpecializeExistingObjectModels() throws {
    let schema = try generate(
      ##"""
      {"type":"object","$defs":{"Record":{"type":"object","properties":{"id":{"type":"integer"}}}},
       "properties":{"plain":{"$ref":"#/$defs/Record"},
       "refined":{"$ref":"#/$defs/Record","enum":[{"id":1},false]}}}
      """##)
    let text = declarations(schema)
    #expect(text.contains("let plain: Record?"))
    #expect(text.contains("let refined: Record?"))
    expectNoDifference(text.components(separatedBy: "struct Record:").count, 2)
    expectNoDifference(cases(schema), [])
  }

  @Test func enumSelectorsSurviveIntersectionsAndRepeatedReferenceUses() throws {
    let schema = try generate(
      ##"""
      {"type":"object","$defs":{"Status":{"type":"string","enum":["draft","done"]}},
       "properties":{"a":{"$ref":"#/$defs/Status"},"b":{"$ref":"#/$defs/Status"},
       "composed":{"allOf":[{"enum":["draft","done"]},{"type":"string"}]}}}
      """##,
      names: .init(caseNames: [
        "#/properties/b/enum/0": "initial",
        "#/properties/composed/allOf/0/enum/1": "finished",
      ]))
    #expect(cases(schema).contains("case initial"))
    #expect(cases(schema).contains("case finished"))
    #expect(throws: SchemaGenerationError.self) {
      try generate(
        ##"""
        {"type":"object","$defs":{"Status":{"enum":["draft"]}},
         "properties":{"a":{"$ref":"#/$defs/Status"},"b":{"$ref":"#/$defs/Status"}}}
        """##,
        names: .init(caseNames: [
          "#/properties/a/enum/0": "first", "#/properties/b/enum/0": "second",
        ]))
    }
  }

  @Test func refinementsKeepOriginalEntryIndicesAndDiagnoseConflictingOrigins() throws {
    let source =
      ##"""
      {"type":"object","$defs":{"State":{"enum":["draft","done"]}},
       "properties":{"refined":{"$ref":"#/$defs/State","enum":["done","missing"]}}}
      """##
    let schema = try generate(
      source, names: .init(caseNames: ["#/properties/refined/enum/0": "finished"]))
    expectNoDifference(cases(schema), ["case draft", "case finished"])
    #expect(throws: SchemaGenerationError.self) {
      try generate(
        source, names: .init(caseNames: ["#/properties/refined/enum/1": "missing"]))
    }
    #expect(throws: SchemaGenerationError.self) {
      try generate(
        source,
        names: .init(caseNames: [
          "#/$defs/State/enum/1": "first", "#/properties/refined/enum/0": "second",
        ]))
    }
    let composed = try generate(
      #"{"allOf":[{"enum":["draft","done"]},{"enum":["done","draft"]}]}"#,
      names: .init(caseNames: ["#/allOf/1/enum/0": "finished"]))
    expectNoDifference(cases(composed), ["case draft", "case finished"])
  }

  @Test func unionsKeepTypedPayloadsAndUnboundedAlternatives() throws {
    let schema = try generate(
      #"{"anyOf":[{"enum":["draft"]},{"type":"string"}]}"#,
      names: .init(typeNames: ["#/anyOf/0": "Status"]))
    #expect(cases(schema).contains("case status(Status)"))
    #expect(cases(schema).contains("case string(String)"))
    let common = try generate(
      ##"{"$defs":{"Status":{"enum":["draft"]}},"anyOf":[{"$ref":"#/$defs/Status"},{"$ref":"#/$defs/Status"}]}"##
    )
    expectNoDifference(cases(common), ["case draft"])
  }

  @Test func namingIsPortableAndInsensitiveToProseOrUnrelatedProperties() throws {
    let source =
      #"{"type":"object","properties":{"a-b":{"enum":["draft"]},"a_b":{"enum":["done"]}}}"#
    let generator = SchemaGenerator(options: .init(output: .models))
    func document(_ directory: String) -> SchemaDocument {
      .init(
        source: source, retrievalURI: URL(fileURLWithPath: "/\(directory)/root.json"),
        logicalName: "Schemas/root.json")
    }
    expectNoDifference(
      try generator.generate(document("one"), referencing: []),
      try generator.generate(document("two"), referencing: []))
    let prose = source.replacingOccurrences(
      of: #""enum":["draft"]"#, with: #""title":"Changed","description":"Prose","enum":["draft"]"#)
    expectNoDifference(declarations(try generate(source)), declarations(try generate(prose)))
    let added = source.replacingOccurrences(
      of: #""properties":{"#, with: #""properties":{"unrelated":{"type":"integer"},"#)
    expectNoDifference(cases(try generate(source)), cases(try generate(added)))
  }
}
