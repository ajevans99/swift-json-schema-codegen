import Foundation
import JSONSchemaCodegenCore
import OrderedJSON

struct HarnessError: Error, CustomStringConvertible {
  let description: String
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
  throw HarnessError(
    description:
      "Usage: GenerateConformance <test-suite-directory> <output-directory> [keyword ...]")
}
let suite = URL(fileURLWithPath: arguments[0], isDirectory: true)
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
var keywords: [String] = []
var outputStyle: SchemaOutputStyle = .tuples
var recursiveObjects: RecursiveObjectStrategy = .valueTypes
var compareModels = false
var optionIndex = 2
while optionIndex < arguments.count {
  let argument = arguments[optionIndex]
  switch argument {
  case "--output-style", "--recursive-objects":
    optionIndex += 1
    guard optionIndex < arguments.count else {
      throw HarnessError(description: "Missing value for \(argument).")
    }
    let value = arguments[optionIndex]
    if argument == "--output-style" {
      switch value {
      case "tuples": outputStyle = .tuples
      case "models": outputStyle = .models
      default: throw HarnessError(description: "Expected tuples or models, got \(value).")
      }
    } else {
      switch value {
      case "value-types": recursiveObjects = .valueTypes
      case "immutable-classes": recursiveObjects = .immutableClasses
      default:
        throw HarnessError(description: "Expected value-types or immutable-classes, got \(value).")
      }
    }
  case "--compare-models":
    compareModels = true
  default:
    guard !argument.hasPrefix("-") else {
      throw HarnessError(description: "Unknown conformance option \(argument).")
    }
    keywords.append(argument)
  }
  optionIndex += 1
}
let selected = Set(keywords.map { $0.hasSuffix(".json") ? $0 : $0 + ".json" })
let styles: [(name: String, options: SchemaGenerationOptions)] =
  compareModels
  ? [
    ("Tuples", .init()),
    ("Models", .init(output: .models, recursiveObjects: recursiveObjects)),
  ]
  : [
    (
      outputStyle == .models ? "Models" : "Tuples",
      .init(output: outputStyle, recursiveObjects: recursiveObjects)
    )
  ]
let manager = FileManager.default
let metaSchemas = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent(
    "../../../../Examples/MetaSchemaExample/Sources/MetaSchemaExample/Schemas"
  )
  .standardizedFileURL
let files = try manager.contentsOfDirectory(
  at: suite.appendingPathComponent("tests/draft2020-12"),
  includingPropertiesForKeys: nil
).filter {
  $0.pathExtension == "json" && (selected.isEmpty || selected.contains($0.lastPathComponent))
}
.sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else { throw HarnessError(description: "No selected 2020-12 test files.") }
try manager.createDirectory(at: output, withIntermediateDirectories: true)

func read(_ url: URL) throws -> JSONValue {
  try JSONValue.parse(String(contentsOf: url, encoding: .utf8))
}

@MainActor func remoteDocuments(for value: JSONValue, base: URL) throws -> [SchemaDocument] {
  var documents: [String: SchemaDocument] = [:]
  var knownResources: Set<String> = [base.absoluteString]
  var pending: [(JSONValue, URL)] = [(value, base)]

  func resource(_ url: URL) -> URL {
    var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)!
    parts.fragment = nil
    return parts.url!
  }

  func visit(_ value: JSONValue, base: URL, collect: Bool) throws {
    guard let object = value.object else { return }
    let base =
      object["$id"]?.string.flatMap { URL(string: $0, relativeTo: base)?.absoluteURL } ?? base
    if !collect { knownResources.insert(resource(base).absoluteString) }
    if collect {
      for keyword in ["$ref", "$dynamicRef"] {
        guard let reference = object[keyword]?.string,
          let target = URL(string: reference, relativeTo: base)?.absoluteURL
        else { continue }
        let uri = resource(target)
        guard !knownResources.contains(uri.absoluteString) else { continue }
        let url: URL
        if uri.host == "localhost", uri.port == 1234 {
          url = suite.appendingPathComponent("remotes").appendingPathComponent(uri.path)
        } else if uri.absoluteString == "https://json-schema.org/draft/2020-12/schema" {
          url = metaSchemas.appendingPathComponent("meta.schema.json")
        } else if uri.absoluteString.hasPrefix("https://json-schema.org/draft/2020-12/meta/") {
          url = metaSchemas.appendingPathComponent("meta")
            .appendingPathComponent(uri.lastPathComponent + ".schema.json")
        } else {
          continue
        }
        guard manager.fileExists(atPath: url.path) else {
          throw HarnessError(description: "Missing official remote fixture: \(url.path)")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let remote = try JSONValue.parse(source)
        knownResources.insert(uri.absoluteString)
        documents[uri.absoluteString] = SchemaDocument(source: source, retrievalURI: uri)
        pending.append((remote, uri))
      }
    }
    for key in ["$defs", "properties", "patternProperties", "dependentSchemas"] {
      if let children = object[key]?.object {
        for child in children.values {
          try visit(child, base: base, collect: collect)
        }
      }
    }
    for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
      for child in object[key]?.array ?? [] {
        try visit(child, base: base, collect: collect)
      }
    }
    for key in [
      "items", "not", "additionalProperties", "propertyNames", "contains",
      "if", "then", "else", "unevaluatedProperties", "unevaluatedItems", "contentSchema",
    ] {
      if let child = object[key] { try visit(child, base: base, collect: collect) }
    }
  }
  while !pending.isEmpty {
    let (document, uri) = pending.removeFirst()
    try visit(document, base: uri, collect: false)
    try visit(document, base: uri, collect: true)
  }
  return documents.keys.sorted().compactMap { documents[$0] }
}

var count = 0
var instanceCount = 0
var failures: [String] = []
var invocations: [String] = []
var generatedGroups = 0
for file in files {
  guard let groups = try read(file).array else {
    throw HarnessError(description: "Expected test groups in \(file.path)")
  }
  var source = "import JSONSchema\nimport JSONSchemaBuilder\n\n"
  for (index, group) in groups.enumerated() {
    guard let schema = group.object?["schema"], let tests = group.object?["tests"]?.array,
      let description = group.object?["description"]?.string
    else { throw HarnessError(description: "Malformed official test group in \(file.path)") }
    let label = "\(file.lastPathComponent) / \(description)"
    let namespace = "Case\(count)"
    let base = URL(string: "https://example.com/codegen/\(file.lastPathComponent)/\(index)")!
    do {
      let document = SchemaDocument(source: try schema.serialized(), retrievalURI: base)
      let remotes = try remoteDocuments(for: schema, base: base)
      var declarations = ""
      for style in styles {
        let generated = try SchemaGenerator(options: style.options).generate(
          document, referencing: remotes)
        declarations += "enum \(namespace)\(style.name) {\n"
        for declaration in generated.declarations { declarations += declaration + "\n" }
        declarations += "static var schema: some JSONSchemaComponent<\(generated.outputType)> {\n"
        declarations += generated.expression + "\n}\n}\n"
      }
      var cases: [String] = []
      for test in tests {
        guard let instance = test.object?["data"], let expected = test.object?["valid"]?.boolean,
          let description = test.object?["description"]?.string
        else { throw HarnessError(description: "Malformed instance in \(label)") }
        cases.append(
          "(\(String(reflecting: description)), \(String(reflecting: try instance.serialized())), \(expected))"
        )
      }
      source += declarations
      source += "@MainActor func run\(namespace)() throws {\n"
      if compareModels {
        source += """
          if \(namespace)Tuples.schema.schemaValue != \(namespace)Models.schema.schemaValue {
            failures.append(\(String(reflecting: label + ": schemaValue differs between output modes")))
          }

          """
      }
      for style in styles {
        source += """
          try check(\(namespace)\(style.name).schema, name: \(String(reflecting: label + " [" + style.name + "]")), cases: [
            \(cases.joined(separator: ",\n"))
          ])

          """
      }
      source += "}\n"
      invocations.append("try run\(namespace)()")
      instanceCount += tests.count
      generatedGroups += 1
    } catch {
      failures.append("\(label): \(error)")
    }
    count += 1
  }
  try source.write(
    to: output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".swift"),
    atomically: true, encoding: .utf8)
}
let summary =
  "Generated \(generatedGroups)/\(count) schema groups, \(instanceCount) instances in \(styles.count) output mode(s); \(failures.count) generation failures."
print(summary)
for failure in failures { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
try (failures.joined(separator: "\n") + "\n").write(
  to: output.appendingPathComponent("generation-failures.txt"), atomically: true, encoding: .utf8)
try
  ("""
import Foundation
import JSONSchema
import JSONSchemaBuilder

var total = 0
var failures: [String] = []
@MainActor func check<C: JSONSchemaComponent>(
  _ component: C, name: String, cases: [(String, String, Bool)]
) throws {
  for (description, source, expected) in cases {
    let instance = try JSONValue.parse(source)
    let validation = component.definition().validate(instance).isValid
    let parsed: Bool
    do {
      _ = try component.parseAndValidate(instance)
      parsed = true
    } catch {
      parsed = false
      if expected { failures.append("\\(name) / \\(description): \\(error)") }
    }
    if validation != expected {
      failures.append("\\(name) / \\(description): validator returned \\(validation), expected \\(expected)")
    }
    if parsed != expected && !expected {
      failures.append("\\(name) / \\(description): parser accepted an invalid instance")
    }
    total += 1
  }
}
\(invocations.joined(separator: "\n"))
print("Conformance: \\(total) instances, \\(failures.count) failures.")
for failure in failures { print(failure) }
if !failures.isEmpty { exit(1) }

""").write(to: output.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
if !failures.isEmpty { exit(1) }
