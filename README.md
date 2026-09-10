# Swift JSON Schema Codegen

Turn JSON Schema documents into typed
[JSONSchemaBuilder](https://github.com/ajevans99/swift-json-schema) expressions.
One generation core powers an attached `@Schema` macro, a command-line tool, and a
SwiftPM build-tool plugin.

This package generates **Swift from JSON Schema**, complementing
`swift-json-schema`'s Swift-to-schema builders and `@Schemable` macro. It does not
generate `Codable` models. Generated components use the existing builder's
`parseAndValidate` API to produce Swift values.

## Requirements

Swift 6.1 or later. Apple platform minimums are macOS 14, iOS 17, tvOS 17,
watchOS 10, Mac Catalyst 17, and visionOS 1, matching the availability of the
builder's variadic property tuples. The CLI and generation core also support Linux.

## Installation

Until the first release is tagged, depend on the main branch:

```swift
dependencies: [
  .package(
    url: "https://github.com/ajevans99/swift-json-schema-codegen.git",
    branch: "main"
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
  "type": "object",
  "properties": {
    "primaryColor": {
      "type": "string",
      "pattern": "^#[0-9a-fA-F]{6}$"
    },
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

`@Schema` adds a typed static `schema` member to an empty namespace enum. You
never repeat the output type: its properties are derived from the JSON.
Public namespace enums expose a public schema member.

An attached macro is intentional. Swift needs an expression macro's result type
before expanding it, so the original `let schema = #schema(jsonLiteral)` design
cannot infer arbitrary tuple fields from schema text. Generating a member
declaration avoids that limitation while retaining fully typed outputs.

The argument must be a compile-time string literal. Ordinary, multiline, and raw
Swift literals are accepted; interpolation and variables are not. Schema errors
are compiler diagnostics containing a JSON Pointer, such as
`#/properties/name/minLength`.

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
| `type: ["T", "null"]` | `T.Output?` |

Swift has no single-element labeled tuples, so singleton objects deliberately
follow the existing builder's unwrapped output. Optional properties add another
optional independently of nullability: an optional nullable string is `String??`,
where `nil` means absent and `.some(nil)` means explicitly null. A required
nullable property must still be present.

Object property names must be ASCII Swift identifiers; keywords such as `class`
are escaped automatically. Unsupported names are diagnosed, not silently
renamed. Undeclared additional properties are validated according to the schema
but are not captured in the tuple.

Use `parseAndValidate`, not just `parse`, to enforce all schema constraints.
`parse` performs the builder's typed conversion; keyword validation belongs to
the JSON Schema validator. `format` follows that validator's dialect and
validation-context behavior rather than imposing new codegen-specific rules.

## Command-line generation

```sh
swift run json-schema-codegen --output-directory Generated \
  Schemas/theme.schema.json
```

Generated Swift imports `JSONSchema` and `JSONSchemaBuilder`, and exposes a
namespace such as `ThemeSchema.schema`. Multiple schema inputs are processed in
one invocation. Generation is deterministic and does not embed timestamps.
Unchanged outputs are not rewritten, and schema errors fail the batch before
any output is modified.

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

Place `*.schema.json` files under that target's `Schemas` directory. Registering
the directory as a resource avoids SwiftPM's unhandled-file warnings; the JSON
resources are not needed at runtime by generated components. The plugin scans
the target directory recursively, excluding hidden files, and invokes
the CLI once for the target's schemas, declares its inputs and outputs for
incremental builds, and places generated Swift in SwiftPM's derived-source
directory rather than editing your source tree.

See [Examples/PluginExample](Examples/PluginExample) for a complete consumer.

## Shared core

Tools can depend on the `JSONSchemaCodegenCore` library without loading the macro
implementation or the runtime schema builder:

```swift
import JSONSchemaCodegenCore

let generated = try SchemaGenerator().generate(#"{"type":"string","minLength":1}"#)
print(generated.expression)
print(generated.outputType) // String
```

The core preserves property order using `OrderedJSON`, emits escaped Swift
literals without evaluating schema text, and performs no file or network I/O.
Failures are `SchemaGenerationError` values with `pointer` and `message` fields.

## Supported subset

The initial implementation supports JSON Schema 2020-12:

| Area | Keywords |
| --- | --- |
| Types | Boolean schemas, `{}`, primitive `type`, one non-null type plus `null` |
| Objects | `properties`, `required`, boolean `additionalProperties`, `minProperties`, `maxProperties` |
| Arrays | Homogeneous `items`, boolean `items`, `minItems`, `maxItems`, `uniqueItems` |
| Strings | `minLength`, `maxLength`, `pattern`, `format` |
| Numbers | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` |
| Values | `enum`, `const` |
| Annotations | `title`, `description`, `default`, `examples`, `readOnly`, `writeOnly`, `deprecated`, `$comment` |
| Metadata | `$id`, `$schema` for the 2020-12 dialect |

Type-specific keywords require an explicit compatible `type`. Required
properties must be declared in `properties`. Numeric representation follows
`OrderedJSON` (`Int`/`Double`); arbitrary-precision JSON numbers are not provided.
Defaults are annotations, not automatic value insertion.

**Unknown or unsupported keywords are errors**, including `$defs`, `$ref`,
composition, tuple arrays, schema-valued additional properties, and custom
extension keywords. Documents are currently independent even in batch mode.
Reference graphs, cross-document resolution, composition, and an OpenAPI 3.1
adapter are follow-on work in [the original plan](schema-macro-plan.md).

## Development

```sh
swift test
bash Tests/CLI/smoke.sh
```

The smoke script also builds and runs the standalone plugin consumer. The
published package depends on the released `swift-json-schema` package, not an
absolute path to a local checkout.

## License

MIT. See [LICENSE](LICENSE).
