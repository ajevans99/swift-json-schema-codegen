import CustomDump
import Foundation
import Testing

@testable import JSONSchemaCodegenCore

struct NamedModelGenerationTests {
  private func generate(
    _ source: String, strategy: RecursiveObjectStrategy = .valueTypes,
    names: SchemaNameOverrides = .init()
  ) throws -> GeneratedSchema {
    try SchemaGenerator(options: .init(output: .models, recursiveObjects: strategy, names: names))
      .generate(source)
  }

  private func declarations(_ schema: GeneratedSchema) -> String {
    schema.declarations.joined(separator: "\n").replacingOccurrences(of: "`", with: "")
  }

  @Test func emptySingletonAndNestedObjectsRemainModels() throws {
    let empty = try generate(#"{"type":"object","additionalProperties":false}"#)
    expectNoDifference(empty.outputType, "Value")
    #expect(declarations(empty).contains("struct Value: Sendable"))
    #expect(declarations(empty).contains("public init()"))
    let nested = try generate(
      #"{"type":"object","properties":{"child":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},"required":["child"]}"#
    )
    #expect(declarations(nested).contains("let child: Child"))
    #expect(declarations(nested).contains("let name: String"))
    #expect(declarations(nested).contains("struct Child"))
  }

  @Test func objectsMapRawOutputsDirectlyIntoModels() throws {
    let schemas: [(String, [String])] = [
      (#"{"type":"object"}"#, []),
      (#"{"type":"object","properties":{"a":{"type":"integer"}}}"#, []),
      (
        #"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"string"}}}"#,
        ["_JSONSchemaCodegenParsedValue.0", "_JSONSchemaCodegenParsedValue.1"]
      ),
      (
        #"{"type":"object","properties":{"a":{"type":["string","null"]}},"additionalProperties":{"type":"integer"}}"#,
        ["_JSONSchemaCodegenParsedValue.0", "_JSONSchemaCodegenParsedValue.1.matches"]
      ),
      (
        #"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"string"}},"additionalProperties":{"type":"boolean"}}"#,
        [
          "_JSONSchemaCodegenParsedValue.0.0", "_JSONSchemaCodegenParsedValue.0.1",
          "_JSONSchemaCodegenParsedValue.1.matches",
        ]
      ),
      (#"{"type":"object","additionalProperties":{"type":"integer"}}"#, ["$0.1.matches"]),
    ]
    for (source, accesses) in schemas {
      let result = try generate(source)
      expectNoDifference(result.expression.components(separatedBy: ".map {").count - 1, 1)
      for access in accesses { #expect(result.expression.contains(access)) }
      #expect(!result.expression.contains("_JSONSchemaCodegenParsedValue.properties"))
    }
  }

  @Test func initializerDefaultsOnlyRepresentAbsence() throws {
    let result = try generate(
      #"{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":["integer","null"]},"c":{"type":["integer","null"]}},"required":["b"]}"#
    )
    let text = declarations(result)
    #expect(text.contains("a: Int? = nil"))
    #expect(text.contains("b: Int?,"))
    #expect(!text.contains("b: Int? = nil"))
    #expect(text.contains("c: Int?? = nil"))
  }

  @Test func rootAliasesNameCompleteContainerAndNullableOutputs() throws {
    let nullable = try generate(
      #"{"type":["object","null"],"properties":{"id":{"type":"integer"}}}"#)
    #expect(declarations(nullable).contains("typealias Value = ObjectValue?"))
    #expect(declarations(nullable).contains("struct ObjectValue"))
    let array = try generate(#"{"type":"array","items":{"type":"object"}}"#)
    #expect(declarations(array).contains("typealias Value = [Item]"))
    let dictionary = try generate(#"{"type":"object","additionalProperties":{"type":"object"}}"#)
    #expect(declarations(dictionary).contains("typealias Value = [String: Entry]"))
    for (source, type) in [
      (#"{"type":"string"}"#, "String"),
      (#"{"type":["integer","null"]}"#, "Int?"),
      ("true", "JSONValue"),
      (#"{"type":"null"}"#, "Void"),
    ] {
      #expect(declarations(try generate(source)).contains("typealias Value = \(type)"))
    }
  }

  @Test func typedExtrasAvoidRealFieldCollision() throws {
    let result = try generate(
      #"{"type":"object","properties":{"additionalProperties":{"type":"string"}},"required":["additionalProperties","token"],"additionalProperties":{"type":"integer"}}"#
    )
    let text = declarations(result)
    #expect(text.contains("let additionalProperties: String"))
    #expect(text.contains("let token: JSONValue"))
    #expect(text.contains("let additionalProperties_2: [String: Int]"))
  }

  @Test func definitionsShareOnlyByIdentity() throws {
    let result = try generate(
      ##"{"type":"object","$defs":{"A":{"type":"object","properties":{"id":{"type":"integer"}}},"B":{"type":"object","properties":{"id":{"type":"integer"}}}},"properties":{"a":{"$ref":"#/$defs/A"},"alsoA":{"$ref":"#/$defs/A"},"b":{"$ref":"#/$defs/B"}}}"##
    )
    let text = declarations(result)
    #expect(text.contains("let a: A?"))
    #expect(text.contains("let alsoA: A?"))
    #expect(text.contains("let b: B?"))
    expectNoDifference(text.components(separatedBy: "struct A:").count, 2)
  }

  @Test func semanticDiscriminatorsAndNoPayloadNull() throws {
    let result = try generate(
      #"{"oneOf":[{"type":"object","properties":{"status":{"const":"ready","type":"string"}},"required":["status"]},{"type":"object","properties":{"status":{"enum":["pending"],"type":"string"}},"required":["status"]}]}"#
    )
    #expect(declarations(result).contains("case ready("))
    #expect(declarations(result).contains("case pending("))
    let scalar = try generate(#"{"type":["string","integer","null"]}"#)
    #expect(declarations(scalar).contains("case null\n"))
    #expect(!declarations(scalar).contains("case null(Void)"))
    #expect(
      declarations(try generate(#"{"anyOf":[{"type":"string"},{"type":"null"}]}"#))
        .contains("typealias Value = String?"))
  }

  @Test func commonModelOutputCollapsesButDifferentDefinitionsDoNot() throws {
    let common = try generate(
      ##"{"$defs":{"A":{"type":"object","properties":{"id":{"type":"integer"}}}},"anyOf":[{"$ref":"#/$defs/A"},{"$ref":"#/$defs/A"}]}"##
    )
    #expect(!declarations(common).contains("enum Value"))
    #expect(declarations(common).contains("struct Value"))
    let different = try generate(
      ##"{"$defs":{"A":{"type":"object"},"B":{"type":"object"}},"anyOf":[{"$ref":"#/$defs/A"},{"$ref":"#/$defs/B"}]}"##
    )
    #expect(declarations(different).contains("enum Value"))
    #expect(declarations(different).contains("case a(A)"))
    #expect(declarations(different).contains("case b(B)"))
  }

  @Test func referenceSpecializationsRetainDistinctShapes() throws {
    let result = try generate(
      ##"{"type":"object","$defs":{"A":{"type":"object","properties":{"base":{"type":"string"}}}},"properties":{"plain":{"$ref":"#/$defs/A"},"extended":{"$ref":"#/$defs/A","properties":{"extra":{"type":"integer"}}}}}"##
    )
    #expect(declarations(result).contains("let plain: A?"))
    #expect(declarations(result).contains("let extended: Extended?"))
    #expect(declarations(result).contains("let extra: Int?"))
  }

  @Test func recursiveCollectionsUnifyWithRootWithoutPublicAdapters() throws {
    let result = try generate(
      ##"{"type":"object","properties":{"children":{"type":"array","items":{"$ref":"#"}}}}"##)
    let text = declarations(result)
    #expect(text.contains("let children: [Value]?"))
    #expect(text.contains("struct Value"))
    #expect(!text.contains("class Value"))
    #expect(!text.contains("public enum Reference"))
    #expect(!text.contains("public struct _JSONSchemaCodegen"))
  }

  @Test func naturalUnionBreaksInlineLayoutCycles() throws {
    let result = try generate(
      ##"{"type":["object","boolean"],"properties":{"not":{"$ref":"#"}}}"##)
    let text = declarations(result)
    #expect(text.contains("indirect enum Value"))
    #expect(text.contains("struct ObjectValue"))
    #expect(text.contains("let not: Value?"))
    #expect(!text.contains("class "))
  }

  @Test func inlineCyclesRequireExplicitClassPolicy() throws {
    let source =
      ##"{"type":["object","null"],"properties":{"value":{"type":"integer"},"next":{"$ref":"#"}},"required":["value","next"]}"##
    #expect(throws: SchemaGenerationError.self) { try generate(source) }
    let result = try generate(source, strategy: .immutableClasses)
    let text = declarations(result)
    #expect(text.contains("final class ObjectValue"))
    #expect(text.contains("let next: ObjectValue?"))
    #expect(text.contains("typealias Value = ObjectValue?"))
    #expect(!text.contains("@unchecked"))
  }

  @Test func overridesMustResolveAndCasesMustActuallyExist() throws {
    let source = #"{"type":"object","properties":{"child":{"type":"object"}}}"#
    let result = try generate(source, names: .init(typeNames: ["#/properties/child": "ChildModel"]))
    #expect(declarations(result).contains("let child: ChildModel?"))
    #expect(throws: SchemaGenerationError.self) {
      try generate(source, names: .init(typeNames: ["#/properties/missing": "Missing"]))
    }
    #expect(throws: SchemaGenerationError.self) {
      try generate(
        #"{"anyOf":[{"type":"string"},{"type":"string"}]}"#,
        names: .init(caseNames: ["#/anyOf/0": "first"]))
    }
    #expect(throws: SchemaGenerationError.self) {
      try generate(source, names: .init(typeNames: ["#/properties/child": "String"]))
    }
  }

  @Test func movingCheckoutAndEditingProseDoNotChangeTypeNames() throws {
    let source =
      #"{"type":"object","properties":{"a-b":{"type":"object"},"a_b":{"type":"object"}}}"#
    let generator = SchemaGenerator(options: .init(output: .models))
    func document(_ directory: String) -> SchemaDocument {
      .init(
        source: source, retrievalURI: URL(fileURLWithPath: "/\(directory)/root.json"),
        logicalName: "Schemas/root.json")
    }
    expectNoDifference(
      try generator.generate(document("one"), referencing: []),
      try generator.generate(document("two"), referencing: []))
    let described = source.replacingOccurrences(
      of: #""type":"object""#, with: #""description":"Text","type":"object""#)
    expectNoDifference(
      declarations(try generate(source)), declarations(try generate(described)))
  }

  @Test func namespaceNameIsReserved() throws {
    let result = try SchemaGenerator(options: .init(output: .models)).generateSyntax(
      #"{"type":"object","properties":{"Widget":{"type":"object"}}}"#, namespaceName: "Widget")
    #expect(!declarations(result.serialized()).contains("struct Widget:"))
  }

  @Test func batchOverridesResolveAcrossAllEntryPoints() throws {
    let source = #"{"type":"object","properties":{"child":{"type":"object"}}}"#
    let a = SchemaDocument(
      source: source, retrievalURI: URL(string: "https://example.com/a")!, logicalName: "a.json")
    let b = SchemaDocument(
      source: source, retrievalURI: URL(string: "https://example.com/b")!, logicalName: "b.json")
    let generator = SchemaGenerator(
      options: .init(
        output: .models,
        names: .init(typeNames: [
          "a.json#/properties/child": "FirstChild",
          "b.json#/properties/child": "SecondChild",
        ])))
    let generated = try generator.generate([a, b])
    #expect(declarations(generated[0]).contains("let child: FirstChild?"))
    #expect(declarations(generated[1]).contains("let child: SecondChild?"))
    expectNoDifference(try generator.generate([b, a]), generated.reversed())
  }

  @Test func annotationOnlyReferenceChangesDoNotDuplicateModels() throws {
    let result = try generate(
      ##"{"type":"object","$defs":{"A":{"type":"object"}},"properties":{"first":{"$ref":"#/$defs/A"},"second":{"$ref":"#/$defs/A","description":"A different description"}}}"##
    )
    #expect(declarations(result).contains("let first: A?"))
    #expect(declarations(result).contains("let second: A?"))
    expectNoDifference(declarations(result).components(separatedBy: "struct A:").count, 2)
  }

  @Test func payloadOverridesAlsoSupplySemanticCaseNames() throws {
    let result = try generate(
      #"{"anyOf":[{"type":"object","properties":{"x":{"type":"integer"}}},{"type":"object","properties":{"y":{"type":"integer"}}}]}"#,
      names: .init(typeNames: ["#/anyOf/0": "FirstPayload", "#/anyOf/1": "SecondPayload"]))
    #expect(declarations(result).contains("case firstPayload(FirstPayload)"))
    #expect(declarations(result).contains("case secondPayload(SecondPayload)"))
  }

  @Test func modelNamesCannotCollideWithNamespaceMembersOrParserBindings() throws {
    let source =
      #"{"type":"object","properties":{"child":{"type":"object","properties":{"number":{"type":"integer"}},"required":["number"]}},"required":["child"]}"#
    let result = try generate(
      source, names: .init(typeNames: ["#/properties/child": "value"]))
    #expect(declarations(result).contains("struct value"))
    #expect(result.expression.contains("_JSONSchemaCodegenParsedValue"))
    for name in ["schema", "_schemaWithDefinition"] {
      do {
        _ = try generate(source, names: .init(typeNames: ["#/properties/child": name]))
        Issue.record("Generated namespace members must be reserved.")
      } catch let error as SchemaGenerationError {
        expectNoDifference(error.pointer, "/properties/child")
        #expect(error.message.contains("reserved"))
      }
    }
  }

  @Test func initializerSelfParameterUsesCollisionSafeInternalName() throws {
    let result = try generate(
      #"{"type":"object","properties":{"self":{"type":"integer"},"_self":{"type":"integer"},"_self_2":{"type":"integer"}},"required":["self","_self","_self_2"]}"#
    )
    let text = declarations(result)
    #expect(text.contains("self _self_3: Int"))
    #expect(text.contains("self.self = _self_3"))
    #expect(text.contains("self._self = _self"))
    #expect(text.contains("self._self_2 = _self_2"))
  }

  @Test func outerTypeRefinementPreservesUnionBranchSelectors() throws {
    let result = try generate(
      #"{"type":"object","anyOf":[{"properties":{"x":{"type":"integer"}},"required":["x"]},{"properties":{"y":{"type":"integer"}},"required":["y"]}]}"#,
      names: .init(caseNames: ["#/anyOf/0": "left", "#/anyOf/1": "right"]))
    let text = declarations(result)
    #expect(text.contains("enum Value"))
    #expect(text.contains("case left("))
    #expect(text.contains("case right("))
    #expect(text.contains("let x: Int"))
    #expect(text.contains("let y: Int"))
  }

  @Test func composedNestedFieldsDoNotReuseUnrefinedModels() throws {
    let result = try generate(
      ##"{"type":"object","$defs":{"Base":{"type":"object","properties":{"child":{"type":"object","properties":{"x":{"type":"integer"}}}}}},"properties":{"plain":{"$ref":"#/$defs/Base"},"refined":{"$ref":"#/$defs/Base","properties":{"child":{"type":"object","properties":{"y":{"type":"string"}}}}}}}"##
    )
    let text = declarations(result)
    expectNoDifference(text.components(separatedBy: "let x: Int?").count, 3)
    expectNoDifference(text.components(separatedBy: "let y: String?").count, 2)
  }

  @Test func validationOnlyRecursionDoesNotCreatePublicLayoutCycles() throws {
    let result = try generate(
      ##"{"type":"string","not":{"type":"object","properties":{"next":{"$ref":"#/not"}}}}"##)
    #expect(declarations(result).contains("typealias Value = String"))
    #expect(!declarations(result).contains("struct "))
    #expect(!declarations(result).contains("Schemable"))
    #expect(result.expression.contains("__codegen_Reference1"))
  }

  @Test func recursiveContainerAliasesHaveLocatedRepresentationDiagnostics() throws {
    let uri = URL(string: "https://example.com/recursive-containers")!
    let schemas: [(String, String)] = [
      (##"{"type":"array","items":{"$ref":"#"}}"##, ""),
      (##"{"type":"object","additionalProperties":{"$ref":"#"}}"##, ""),
      (
        ##"{"type":"object","properties":{"items":{"$ref":"#/$defs/Loop"}},"$defs":{"Loop":{"type":"array","items":{"$ref":"#/$defs/Loop"}}}}"##,
        "/$defs/Loop"
      ),
    ]
    for (source, pointer) in schemas {
      for strategy in [RecursiveObjectStrategy.valueTypes, .immutableClasses] {
        do {
          _ = try SchemaGenerator(options: .init(output: .models, recursiveObjects: strategy))
            .generate(.init(source: source, retrievalURI: uri), referencing: [])
          Issue.record("Recursive container aliases must not escape as invalid Swift.")
        } catch let error as SchemaGenerationError {
          expectNoDifference(error.pointer, pointer)
          expectNoDifference(error.documentURI, uri)
          #expect(error.message.contains("recursive container alias"))
          #expect(error.message.contains("Swift forbids recursive typealiases"))
        }
      }
    }
  }

  @Test func overrideFragmentsDecodePercentEncodingExactlyOnce() throws {
    let source =
      #"{"$id":"https://example.com/canonical","type":"object","properties":{"a/b~c":{"type":"object"},"literal%7E1":{"type":"object"}}}"#
    let document = SchemaDocument(
      source: source, retrievalURI: URL(string: "https://example.com/retrieved")!,
      logicalName: "input.json")
    for prefix in [
      "", "https://example.com/retrieved", "https://example.com/canonical", "input.json",
    ] {
      let result = try SchemaGenerator(
        options: .init(
          output: .models,
          names: .init(typeNames: [
            prefix + "#/properties/a%7E1b~0c": "EscapedProperty",
            prefix + "#/properties/literal%257E1": "LiteralPercent",
          ]))
      ).generate(document, referencing: [])
      #expect(declarations(result).contains("struct EscapedProperty"))
      #expect(declarations(result).contains("struct LiteralPercent"))
    }
    let cases = try generate(
      #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
      names: .init(caseNames: ["#/anyOf/%30": "text"]))
    #expect(declarations(cases).contains("case text(String)"))
  }
}
