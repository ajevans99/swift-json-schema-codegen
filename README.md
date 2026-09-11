# Swift JSON Schema Codegen

[![CI](https://github.com/ajevans99/swift-json-schema-codegen/actions/workflows/ci.yml/badge.svg)](https://github.com/ajevans99/swift-json-schema-codegen/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fajevans99%2Fswift-json-schema-codegen%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ajevans99/swift-json-schema-codegen)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fajevans99%2Fswift-json-schema-codegen%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ajevans99/swift-json-schema-codegen)

Turn JSON Schema documents into typed
[JSONSchemaBuilder](https://github.com/ajevans99/swift-json-schema) expressions.
Use `@Schema` for inline schemas, or generate Swift from schema files with the
command-line tool or SwiftPM build plugin.

Generated components parse and validate JSON into Swift values: primitives,
labeled tuples, arrays, and enums. They are not `Codable` models.

## Requirements

Swift 6.1 or later. Supports macOS 14, iOS 17, tvOS 17, watchOS 10,
Mac Catalyst 17, visionOS 1, and later. The CLI and generation core also support Linux.

## Installation

Add the package dependency:

```swift
dependencies: [
  .package(
    url: "https://github.com/ajevans99/swift-json-schema-codegen.git",
    from: "0.2.0"
  )
]
```

Add the library product to your target:

```swift
.product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
```

## Inline schemas

```swift
import JSONSchemaCodegen

@Schema("""
{
  "$defs": {
    "hexColor": {
      "type": "string",
      "pattern": "^#[0-9a-fA-F]{6}$"
    }
  },
  "type": "object",
  "properties": {
    "primaryColor": { "$ref": "#/$defs/hexColor" },
    "iconUrl": { "type": "string" }
  },
  "required": ["primaryColor"],
  "additionalProperties": false
}
""")
enum ThemeSchema {}

let theme = try ThemeSchema.schema.parseAndValidate(
  instance: ##"{"primaryColor":"#336699"}"##
)
// theme.primaryColor: String
// theme.iconUrl: String?
```

`@Schema` adds a static `schema` member to an empty enum and derives its output
type from the JSON. A public enum gets a public `schema` member. The enum must
be non-generic and outside generic contexts.

The argument must be a string literal: ordinary, multiline, and raw literals
are supported, but variables and interpolation are not. Invalid or unsupported
schemas produce compiler errors with a JSON Pointer to the problem, such as
`#/properties/primaryColor/pattern`.

### Output types

| Schema | Swift output |
| --- | --- |
| `string` | `String` |
| `integer` | `Int` |
| `number` | `Double` |
| `boolean` | `Bool` |
| `null` | `Void` |
| Boolean schema or unconstrained `{}` | `JSONValue` |
| Homogeneous array | `[Item.Output]` |
| Object with two or more properties | Labeled tuple in schema property order |
| Object with one property | The property's value, unwrapped |
| Object with no declared properties | `Void` |
| `type: ["string", "null"]` | `String?` |

Property presence and nullability are separate. An optional nullable string is
`String??`: `nil` means absent, and `.some(nil)` means explicitly null. A required
nullable property must be present.

Object property names must be ASCII Swift identifiers; keywords such as `class`
are escaped automatically. Other names produce an error. Additional properties
are validated according to the schema but are not included in the tuple.

Call `parseAndValidate` to parse a value and enforce its schema constraints.
`parse` alone performs typed conversion without checking every keyword.
`format` validation follows `swift-json-schema`'s dialect and validation context.

## Reusable schemas and references

Use `$defs` and `$ref` to share definitions. References are resolved during
generation and retain the referenced definition's Swift output type.

The [plugin example](Examples/PluginExample) uses shared color, typography, and
spacing definitions across theme and application-settings schemas:

| Example | What it demonstrates |
| --- | --- |
| [Design tokens](Examples/PluginExample/Sources/PluginExample/Schemas/Common/design-tokens.schema.json) | Reusable hex colors, semantic palettes, typography, and spacing; nested resource IDs and anchors |
| [Theme](Examples/PluginExample/Sources/PluginExample/Schemas/theme.schema.json) | A theme assembled from shared tokens, with body/heading typography and optional corner radius |
| [App settings](Examples/PluginExample/Sources/PluginExample/Schemas/App/app-settings.schema.json) | Cross-document references for appearance, typography overrides, layout, and recent accent colors |
| [JSON instances](Examples/PluginExample/Sources/PluginExample/Fixtures) | Valid payloads plus invalid colors, missing typography fields, excessive scores, and duplicate colors |

Supported references include:

- Local JSON Pointers, including escaped `/` and `~` tokens and percent-encoded
  fragments.
- Document retrieval URIs and canonical `$id` aliases.
- Nested `$id` resources, which establish new bases for relative references.
- Static `$anchor` names, scoped to their containing resource.
- Relative and absolute references to other explicitly supplied batch documents.

The macro resolves references within its literal. The CLI and plugin resolve
references across all files in a batch. Referenced files must be included in the
batch; the generator does not fetch URLs or read files implicitly.

Relative references use the nearest enclosing `$id`, or the input file's URI
when no `$id` is present. An `$id` can identify an embedded schema rather than a
file: the example's `typography-style.schema.json` resource is defined inside
the shared design-token document.

Constraints alongside `$ref` apply in addition to the referenced schema, using
the same rules as [`allOf`](#composition). Generated schemas inline the
referenced definitions and are self-contained.

Missing references, duplicate IDs or anchors, and recursive references produce
errors with the source document and JSON Pointer.

## Composition

| Keyword | Swift output and behavior |
| --- | --- |
| `allOf` | Intersects types and combines compatible object fields in declaration order; requiredness is the union of the branches' required names |
| `anyOf` | The common output type when branch types match; otherwise a generated enum. Returns the first schema-valid, successfully parsed branch in schema order |
| `oneOf` | The common output type or a generated enum. `parseAndValidate` requires exactly one schema-valid branch |
| `not` | Retains the surrounding schema's output type, or `JSONValue` when unconstrained; rejects instances matching the negated schema |

When union branches have different output types, the generator adds a public
`Sendable` enum inside the schema enum:

```swift
import JSONSchemaCodegen

@Schema("""
{"oneOf":[{"type":"string"},{"type":"number"}]}
""")
enum TokenSchema {}

let token = try TokenSchema.schema.parseAndValidate(instance: "12")
switch token {
case .option1(let text):
  print(text) // String
case .option2(let number):
  print(number) // Double
}
```

Generated enums are named `Union1`, `Union2`, and so on. Cases follow schema
branch order, so reordering branches can change the generated API. Unions with
the same sequence of payload types share an enum within the namespace.

`allOf` combines object fields and intersects their constraints. A field required
by any branch is required in the output. Required fields without a declared
schema use `JSONValue`, as do intersections with no explicit type.

Each branch still validates independently. An object with
`additionalProperties: false` will reject fields introduced by another branch,
and a weaker bound in one branch does not override a stronger bound in another.
Incompatible type intersections accept no instances.

## OpenAPI 3.1 integration

`OpenAPISchemaGenerator` generates Swift from an OpenAPI 3.1 JSON document's
`components.schemas`. It preserves component names and order, resolves
`#/components/schemas/...` references, and respects `$id` scopes.

```swift
import Foundation
import JSONSchemaCodegenCore

let url = URL(fileURLWithPath: "style-api.openapi.json")
let components = try OpenAPISchemaGenerator().generateComponents(
  in: SchemaDocument(
    source: try String(contentsOf: url, encoding: .utf8),
    retrievalURI: url
  )
)
for component in components {
  print(component.name, component.schema.outputType)
}
```

See the [OpenAPI example](Examples/OpenAPIExample) for a Style API with shared
typography and color schemas, composed themes, and ready/pending response enums.

The adapter handles named components, not inline operation schemas or HTTP
client generation. It accepts the OAS 3.1 base dialect and JSON Schema 2020-12
for the [supported keywords](#supported-subset). YAML, OpenAPI 3.0, external
documents, custom dialects, and OpenAPI-only keywords such as `discriminator`
are not supported.

## Command-line generation

```sh
swift run json-schema-codegen --output-directory Generated \
  Schemas/theme.schema.json Schemas/shared.schema.json
```

This generates `ThemeSchema.generated.swift` and `SharedSchema.generated.swift`,
each containing an enum with a static `schema` member. The generated files import
`JSONSchema` and `JSONSchemaBuilder`.

All inputs share a reference registry, regardless of argument order. Output is
deterministic, unchanged files are not rewritten, and schema errors fail the
batch before any output is modified.

Filenames must end in `.schema.json`. Basenames start with an ASCII letter and
contain letters, digits, and single `-` or `_` separators. For example,
`user-score.schema.json` generates `UserScoreSchema.generated.swift`. Names that
collide, including case-insensitive collisions, are rejected.

## Build-tool plugin

Attach the plugin to a target that links the library:

```swift
.executableTarget(
  name: "Example",
  dependencies: [
    .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
  ],
  resources: [.copy("Schemas")],
  plugins: [
    .plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")
  ]
)
```

Place `*.schema.json` files under the target's `Schemas` directory. The resource
declaration avoids SwiftPM's unhandled-file warnings; generated components do
not read those resources at runtime.

The plugin scans the target directory recursively, excluding hidden files, and
processes its schemas as one batch. Generated Swift goes into SwiftPM's
derived-source directory. Changes to shared schemas trigger regeneration of
dependent declarations.

See [Examples/PluginExample](Examples/PluginExample) for a complete package.

## Shared core

Use `JSONSchemaCodegenCore` to build your own generation tools:

```swift
import JSONSchemaCodegenCore

let generated = try SchemaGenerator().generate(#"{"type":"string","minLength":1}"#)
print(generated.expression)
print(generated.outputType) // String
```

`GeneratedSchema` provides the source expression, its output type, and any
supporting `declarations`. Emit all declarations inside the same namespace as
the `schema` member; they may include enums and static helpers.

Emission uses SwiftSyntax nodes internally; these three public properties remain
`String`, `String`, and `[String]`. Generated source uses two-space indentation,
multiline closures, and one modifier per line. String literals may use raw
delimiters to preserve their exact Unicode scalars. Syntax nodes are checked
before emission; malformed nodes produce a located `SchemaGenerationError` with
compiler-style generated-source diagnostics. Round-trip parser tests and
generated-consumer compilation cover the serialized source.

SwiftSyntax is a generation-time dependency of the core, CLI, and macro tool,
not a runtime dependency of applications using the generated schemas.

The core performs no file or network I/O. Errors are `SchemaGenerationError`
values with `pointer`, `message`, and an optional `documentURI`.

For multi-document generation, provide a URI for each input. Results follow
input order:

```swift
import Foundation
import JSONSchemaCodegenCore

let folder = URL(fileURLWithPath: "/project/Schemas", isDirectory: true)
let inputs = try ["theme.schema.json", "shared.schema.json"].map { name in
  let url = folder.appendingPathComponent(name)
  return SchemaDocument(
    source: try String(contentsOf: url, encoding: .utf8),
    retrievalURI: url
  )
}
let generated = try SchemaGenerator().generate(inputs)
```

## Supported subset

The package supports these JSON Schema 2020-12 keywords:

| Area | Keywords |
| --- | --- |
| Types | Boolean schemas, `{}`, primitive `type`, one non-null type plus `null` |
| Objects | `properties`, `required`, boolean `additionalProperties`, `minProperties`, `maxProperties` |
| Arrays | Homogeneous `items`, boolean `items`, `minItems`, `maxItems`, `uniqueItems` |
| Strings | `minLength`, `maxLength`, `pattern`, `format` |
| Numbers | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` |
| Values | `enum`, `const` |
| References | `$defs`, non-recursive `$ref`, nested `$id`, static `$anchor`, offline cross-document resolution |
| Composition | `allOf`, `anyOf`, `oneOf`, `not`, including same-output and generated-enum unions |
| Annotations | `title`, `description`, `default`, `examples`, `readOnly`, `writeOnly`, `deprecated`, `$comment` |
| Metadata | `$id`, `$schema` for the 2020-12 dialect |

Standalone type-specific keywords require an explicit compatible `type`;
composition may establish the type through another branch. Standalone required
properties must be declared in `properties`. Numeric representation follows
`OrderedJSON` (`Int`/`Double`); arbitrary-precision JSON numbers are not provided.
Defaults are annotations, not automatic value insertion.

Unsupported keywords in reachable schemas produce errors. This includes dynamic
references, tuple arrays, schema-valued additional properties, and custom
extension keywords. Recursive schemas are not supported. Generation is limited
to 128 levels of nesting and 10,000 emitted nodes per schema.

## Development

```sh
swift test
bash Tests/CLI/smoke.sh
bash Tests/OpenAPI/smoke.sh
```

The smoke scripts generate Swift, then build and run the plugin and OpenAPI
example consumers.

## License

MIT. See [LICENSE](LICENSE).
