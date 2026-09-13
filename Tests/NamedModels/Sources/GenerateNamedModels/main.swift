import Foundation
import JSONSchemaCodegenCore

struct HarnessError: Error, CustomStringConvertible {
  let description: String
}

struct Fixture {
  let file: String
  let namespace: String
  var requiresClasses = false
  var names = SchemaNameOverrides()
}

func generateModels() throws {
  guard CommandLine.arguments.count == 2 else {
    throw HarnessError(description: "Usage: GenerateNamedModels <generated-source-directory>")
  }
  let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures").standardizedFileURL
  let cases: [Fixture] = [
    .init(
      file: "person", namespace: "PersonSchema",
      names: .init(typeNames: ["#/$defs/Address": "Address"])),
    .init(file: "singleton", namespace: "SingletonSchema"),
    .init(file: "empty", namespace: "EmptySchema"),
    .init(
      file: "records", namespace: "RecordsSchema",
      names: .init(typeNames: ["#/items": "Record"])),
    .init(
      file: "dictionary", namespace: "DictionarySchema",
      names: .init(typeNames: ["#/$defs/Entry": "Entry"])),
    .init(file: "extras", namespace: "ExtrasSchema"),
    .init(file: "extras-collision", namespace: "ExtrasCollisionSchema"),
    .init(file: "awkward-keys", namespace: "AwkwardKeysSchema"),
    .init(file: "member-keywords", namespace: "MemberKeywordsSchema"),
    .init(
      file: "lowercase-name", namespace: "LowercaseNameSchema",
      names: .init(typeNames: ["#/properties/child": "value"])),
    .init(
      file: "response", namespace: "ResponseSchema",
      names: .init(typeNames: ["#/oneOf/0": "Ready", "#/oneOf/1": "Pending"])),
    .init(
      file: "overlap", namespace: "OverlapSchema",
      names: .init(caseNames: ["#/anyOf/0": "left", "#/anyOf/1": "right"])),
    .init(
      file: "equal-shapes", namespace: "EqualShapesSchema",
      names: .init(typeNames: ["#/oneOf/0": "Accepted", "#/oneOf/1": "Rejected"])),
    .init(file: "scalars", namespace: "ScalarsSchema"),
    .init(file: "nullable-scalar", namespace: "NullableScalarSchema"),
    .init(file: "null", namespace: "NullSchema"),
    .init(file: "anything", namespace: "AnythingSchema"),
    .init(file: "prefix", namespace: "PrefixSchema"),
    .init(file: "recursive-tree", namespace: "RecursiveTreeSchema"),
    .init(file: "linked-list", namespace: "LinkedListSchema", requiresClasses: true),
    .init(file: "mutual", namespace: "MutualSchema", requiresClasses: true),
    .init(file: "recursive-union", namespace: "RecursiveUnionSchema"),
    .init(file: "dynamic-tree", namespace: "DynamicTreeSchema"),
    .init(file: "enum-status", namespace: "StatusSchema"),
    .init(file: "enum-inferred", namespace: "InferredEnumSchema"),
    .init(file: "enum-nullable", namespace: "NullableEnumSchema"),
    .init(file: "enum-inferred-nullable", namespace: "InferredNullableEnumSchema"),
    .init(file: "enum-unicode", namespace: "UnicodeEnumSchema"),
    .init(
      file: "enum-awkward", namespace: "AwkwardEnumSchema",
      names: .init(caseNames: ["#/enum/0": "repeated", "#/enum/1": "repeated"])),
    .init(
      file: "enum-container", namespace: "EnumContainerSchema",
      names: .init(typeNames: [
        "#/$defs/State": "State",
        "#/$defs/Twin": "Twin",
        "#/$defs/NullableState": "NullableState",
      ])),
    .init(
      file: "enum-compositions", namespace: "EnumCompositionsSchema",
      names: .init(
        typeNames: [
          "#/$defs/State": "State",
          "#/properties/intersection": "Intersection",
          "#/properties/refined": "Refined",
          "#/properties/either": "Either",
          "#/properties/either/anyOf/0": "EitherLeft",
          "#/properties/either/anyOf/1": "EitherRight",
          "#/properties/exclusive": "Exclusive",
          "#/properties/exclusive/oneOf/0": "ExclusiveLeft",
          "#/properties/exclusive/oneOf/1": "ExclusiveRight",
        ],
        caseNames: [
          "#/properties/intersection/allOf/1/enum/0": "finished",
          "#/properties/refined/enum/0": "completed",
          "#/properties/either/anyOf/0": "left",
          "#/properties/either/anyOf/1": "right",
          "#/properties/exclusive/oneOf/0": "left",
          "#/properties/exclusive/oneOf/1": "right",
        ])),
    .init(file: "enum-legacy", namespace: "LegacyEnumSchema"),
  ]
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

  func wrap(_ generated: GeneratedSchema, namespace: String) -> String {
    """
    import JSONSchema
    import JSONSchemaBuilder

    public enum \(namespace) {
      \(generated.declarations.joined(separator: "\n"))
      public static var schema: some JSONSchemaComponent<\(generated.outputType)> {
        \(generated.expression)
      }
    }

    """
  }

  var parityChecks: [String] = []
  var byteCounts = [0, 0]
  var generationFailures: [String] = []
  for fixture in cases {
    do {
      let filename = fixture.file + ".schema.json"
      let source = try String(
        contentsOf: fixtures.appendingPathComponent(filename), encoding: .utf8)
      let options = SchemaGenerationOptions(
        output: .models,
        recursiveObjects: fixture.requiresClasses ? .immutableClasses : .valueTypes,
        names: fixture.names
      )
      func document(_ directory: String) -> SchemaDocument {
        SchemaDocument(
          source: source,
          retrievalURI: URL(fileURLWithPath: "/\(directory)/Schemas/\(filename)"),
          logicalName: "Schemas/\(filename)"
        )
      }
      let models = try SchemaGenerator(options: options).generate(
        document("first-checkout"), referencing: [])
      guard models.outputType == "Value" else {
        throw HarnessError(description: "\(filename) did not expose the complete output as Value.")
      }
      let relocated = try SchemaGenerator(options: options).generate(
        document("relocated-checkout"), referencing: [])
      guard models.outputType == relocated.outputType,
        models.declarations == relocated.declarations,
        models.expression == relocated.expression
      else {
        throw HarnessError(
          description: "\(filename) changed generated source after checkout relocation.")
      }
      let tuples = try SchemaGenerator().generate(document("first-checkout"), referencing: [])
      if fixture.requiresClasses {
        do {
          _ = try SchemaGenerator(options: .init(output: .models, names: fixture.names)).generate(
            document("first-checkout"), referencing: [])
          throw HarnessError(
            description: "\(filename) silently accepted an inline value-layout cycle.")
        } catch let issue as SchemaGenerationError {
          let description = String(describing: issue).lowercased()
          guard description.contains("layout") || description.contains("inline") else {
            throw HarnessError(
              description: "\(filename) produced an unrelated diagnostic: \(issue)")
          }
        }
      }
      for (index, result) in [models, tuples].enumerated() {
        let namespace = fixture.namespace + (index == 0 ? "" : "Tuples")
        let emitted = wrap(result, namespace: namespace)
        try emitted.write(
          to: output.appendingPathComponent(namespace + ".swift"),
          atomically: true, encoding: .utf8)
        byteCounts[index] += emitted.utf8.count
      }
      parityChecks.append(
        "\(fixture.namespace).schema.schemaValue == \(fixture.namespace)Tuples.schema.schemaValue")
    } catch {
      generationFailures.append("\(fixture.file): \(error)")
    }
  }
  do {
    let source = try String(
      contentsOf: fixtures.appendingPathComponent("options.openapi.json"), encoding: .utf8)
    let document = SchemaDocument(
      source: source, retrievalURI: URL(string: "https://example.com/options.openapi.json")!,
      logicalName: "options.openapi.json")
    let names = SchemaNameOverrides(
      typeNames: [
        "#/components/schemas/Envelope/properties/payload": "Message",
        "#/components/schemas/Envelope/properties/result": "Outcome",
        "#/components/schemas/Envelope/properties/status": "Lifecycle",
      ],
      caseNames: [
        "#/components/schemas/Envelope/properties/result/oneOf/0": "text",
        "#/components/schemas/Envelope/properties/result/oneOf/1": "count",
        "#/components/schemas/Envelope/properties/status/enum/1": "working",
      ])
    for (index, options) in [
      SchemaGenerationOptions(output: .models, names: names), .init(),
    ].enumerated() {
      let components = try OpenAPISchemaGenerator(options: options).generateComponents(in: document)
      guard components.count == 1, let component = components.first else {
        throw HarnessError(
          description: "OpenAPI override fixture did not emit exactly one component.")
      }
      let namespace = "OpenAPIOptionsSchema" + (index == 0 ? "" : "Tuples")
      let emitted = wrap(component.schema, namespace: namespace)
      try emitted.write(
        to: output.appendingPathComponent(namespace + ".swift"),
        atomically: true, encoding: .utf8)
      byteCounts[index] += emitted.utf8.count
    }
    parityChecks.append(
      "OpenAPIOptionsSchema.schema.schemaValue == OpenAPIOptionsSchemaTuples.schema.schemaValue")
  } catch {
    generationFailures.append("OpenAPI options: \(error)")
  }
  guard generationFailures.isEmpty else {
    throw HarnessError(description: generationFailures.joined(separator: "\n"))
  }
  do {
    let source = try String(
      contentsOf: fixtures.appendingPathComponent("lowercase-name.schema.json"), encoding: .utf8)
    _ = try SchemaGenerator(
      options: .init(output: .models, names: .init(typeNames: ["#/properties/child": "schema"]))
    ).generate(source)
    throw HarnessError(description: "A model named schema collided with the namespace entry point.")
  } catch let issue as SchemaGenerationError {
    guard issue.pointer == "/properties/child",
      issue.message.lowercased().contains("reserved")
        || issue.message.lowercased().contains("collid")
    else {
      throw HarnessError(
        description: "Namespace collision produced an unrelated diagnostic: \(issue)")
    }
    for reserved in ["rawValue", "RawValue", "hash", "hashValue"] {
      do {
        _ = try SchemaGenerator(
          options: .init(output: .models, names: .init(caseNames: ["#/enum/0": reserved]))
        ).generate(#"{"type":"string","enum":["draft"]}"#)
        throw HarnessError(description: "Enum case override accepted reserved member \(reserved).")
      } catch let issue as SchemaGenerationError {
        guard issue.pointer == "/enum/0",
          issue.message.lowercased().contains("reserved")
            || issue.message.lowercased().contains("collid")
        else {
          throw HarnessError(
            description: "Reserved enum member produced an unrelated error: \(issue)")
        }
      }
    }
  }
  try """
  public func schemasHaveIdenticalValidationValues() -> Bool {
    \(parityChecks.joined(separator: "\n    && "))
  }

  """.write(
    to: output.appendingPathComponent("ValidationParity.swift"),
    atomically: true, encoding: .utf8)
  print(
    "Generated \(cases.count + 1) named/tuple consumer pairs: "
      + "\(byteCounts[0]) named bytes, \(byteCounts[1]) tuple bytes. "
      + "Relocation and explicit value-layout policy checks passed.")
}

do {
  try generateModels()
} catch {
  FileHandle.standardError.write(Data("Named-model generation failed: \(error)\n".utf8))
  exit(1)
}
