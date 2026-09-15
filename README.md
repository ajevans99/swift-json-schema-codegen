# Swift JSON Schema Codegen

[![CI](https://github.com/ajevans99/swift-json-schema-codegen/actions/workflows/ci.yml/badge.svg)](https://github.com/ajevans99/swift-json-schema-codegen/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fajevans99%2Fswift-json-schema-codegen%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ajevans99/swift-json-schema-codegen)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fajevans99%2Fswift-json-schema-codegen%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ajevans99/swift-json-schema-codegen)

Generate Swift types and JSON parsers from JSON Schema. Define a schema inline
with `@Schema`, or generate Swift source from `.schema.json` files using the CLI
or SwiftPM build plugin.

The generated code uses
[JSONSchemaBuilder](https://github.com/ajevans99/swift-json-schema) to parse JSON
and validate it against the schema. Output can be tuples or named models; it is
not `Codable` synthesis or an HTTP client generator.

## Installation

Requires **Swift 6.1 or later**. Deployment targets are macOS 14, iOS 17, tvOS 17,
watchOS 10, Mac Catalyst 17, and visionOS 1 or later. The CLI and generation core
also support Linux.

**This README describes `main`, including unreleased features.** Named models,
typed string enums, and shared-root encoding are not in the latest tagged
release, [0.2.0](https://github.com/ajevans99/swift-json-schema-codegen/releases/tag/v0.2.0).
To use the examples below, add the development branch to `Package.swift`:

```swift
dependencies: [
  .package(
    url: "https://github.com/ajevans99/swift-json-schema-codegen.git",
    branch: "main"
  )
]
```

Then add the library to your target's dependencies:

```swift
.product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
```

SwiftPM resolves the JSON Schema runtime dependency automatically. For a tagged
release instead, use `from: "0.2.0"` and follow the
[0.2.0 documentation](https://github.com/ajevans99/swift-json-schema-codegen/blob/v0.2.0/README.md).

## Quick start

```swift
import JSONSchemaCodegen

@Schema(
  """
  {
    "type": "object",
    "properties": {
      "name": { "type": "string", "minLength": 1 },
      "age": { "type": "integer", "minimum": 0 }
    },
    "required": ["name"],
    "additionalProperties": false
  }
  """,
  output: .models
)
enum PersonSchema {}

let person: PersonSchema.Value = try PersonSchema.schema.parseAndValidate(
  instance: #"{"name":"Ada","age":36}"#
)

print(person.name) // Ada
// person.age is Int? because "age" is not required.
```

`@Schema` adds a static `schema` member and, in model mode, named types inside
the enum. Here, `PersonSchema.Value` is an immutable `Sendable` struct with
`name: String` and `age: Int?`. Missing required fields, negative ages, and
unknown properties cause `parseAndValidate` to throw.

The macro takes a string literal and must be attached to an empty enum outside
generic contexts. Invalid schemas produce compiler diagnostics with a JSON
Pointer identifying the problem.

### Choosing an output type

Use `output: .models` when you want named types, initializers, and typed string
enums. Omitting it uses the default tuple output: the example above would return
`(name: String, age: Int?)` without generating a `Value` model.

Two details are worth knowing before choosing:

- In tuple mode, an object with one property returns that property's value,
  not a one-field tuple. An object with no declared properties returns `Void`.
- Optional and nullable are different. An optional nullable string is `String??`:
  `nil` means absent, while `.some(nil)` means JSON null.

Use **`parseAndValidate` for input validation**. `parse` performs typed conversion
but does not check every schema constraint. Model initializers do not validate
constraints either.

See [output types and schema support](Documentation/SchemaSupport.md) for
collections, unions, recursion, and validation limits.

## Generate from files

### Command-line tool

From a checkout of this repository:

```sh
swift run json-schema-codegen \
  --output-style models \
  --output-directory Generated \
  Examples/PluginExample/Sources/PluginExample/Schemas/Common/design-tokens.schema.json \
  Examples/PluginExample/Sources/PluginExample/Schemas/theme.schema.json
```

This writes `DesignTokensSchema.generated.swift` and
`ThemeSchema.generated.swift`. Each contains a public namespace enum with a
static `schema` member and its generated models.

Include the generated Swift in your target. It imports `JSONSchema` and
`JSONSchemaBuilder`; linking `JSONSchemaCodegen` as above makes those modules
available. Schemas are compiled into the generated code, so the input files are
not needed at runtime.

Pass all referenced schema files in the same invocation. **References are
resolved offline**: a `$ref` URL is an identifier, not a request to download a
schema.

### SwiftPM build plugin

For generation during a build, attach the plugin to your target:

```swift
.executableTarget(
  name: "Example",
  dependencies: [
    .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
  ],
  exclude: ["json-schema-codegen.json"],
  resources: [.copy("Schemas")],
  plugins: [
    .plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")
  ]
)
```

Put your `.schema.json` files in `Sources/Example/Schemas/` and create
`Sources/Example/json-schema-codegen.json`:

```json
{
  "version": 1,
  "output": "models"
}
```

The plugin generates and compiles the Swift sources automatically. It discovers
schemas recursively under the target directory and resolves them as one batch.
The resource declaration avoids SwiftPM's unhandled-file warnings; the generated
parsers do not load those resources.

See the [complete plugin example](Examples/PluginExample) or the
[generation guide](Documentation/Generation.md) for configuration, filename
rules, naming overrides, and the core API.

## Scope and documentation

The generator targets **JSON Schema 2020-12**, including composition, local and
cross-document references, and recursive schemas. It does not support custom
dialects or every possible Swift representation of a schema. Validation and
typed output are separate: a constraint can be enforced without appearing as a
Swift field or type.

| Guide | Contents |
| --- | --- |
| [Output types and schema support](Documentation/SchemaSupport.md) | Type mapping, string enums, recursion, supported keywords, and limits |
| [Generation](Documentation/Generation.md) | CLI options, plugin configuration, naming, references, and core APIs |
| [Shared schemas and encoding](Documentation/SharedSchemas.md) | Multiple roots sharing model types, and mapping models back to `JSONValue` |
| [OpenAPI example](Examples/OpenAPIExample) | Generating types from OpenAPI 3.1 JSON `components.schemas` |
| [Official meta-schema example](Examples/MetaSchemaExample) | Offline generation from the official 2020-12 meta-schemas |

The OpenAPI adapter handles schema components, not operations or transport. For
operation clients, see
[Swift OpenAPI Schema Codegen](https://github.com/ajevans99/swift-openapi-schema-codegen).

## Development

Run the package tests from the repository root:

```sh
swift test
```

The [CI workflow](.github/workflows/ci.yml) also runs generated-code consumers on
macOS and Linux. For a local end-to-end check of the CLI and plugin:

```sh
bash Tests/CLI/smoke.sh
```

The [conformance harness](Tests/Conformance) checks generated code against the
official JSON Schema Test Suite. Its README covers fixture setup, measured
coverage, and known failures.

## License

MIT. See [LICENSE](LICENSE).
