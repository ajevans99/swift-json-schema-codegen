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

Add the package dependency:

```swift
dependencies: [
  .package(
    url: "https://github.com/ajevans99/swift-json-schema-codegen.git",
    from: "0.1.0"
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

## Reusable schemas and references

`$defs` and `$ref` work in both inline macros and file-based generation. References
are resolved at generation time, not at runtime; their outputs keep the same
Swift types as the referenced definitions.

For a theme, reusable definitions might describe hex colors, spacing scales, and
typography. Several button variants can reference the same typography object
without repeating its properties or numeric constraints. The
[plugin example](Examples/PluginExample) contains authored theme/design-token and
application-settings schemas, with valid and invalid JSON instances. These are
practical examples, not a claim of conformance to the DTCG design-token standard.

| Example | What it demonstrates |
| --- | --- |
| [Design tokens](Examples/PluginExample/Sources/PluginExample/Schemas/Common/design-tokens.schema.json) | Reusable hex colors, semantic palettes, typography, and spacing; nested resource IDs and anchors |
| [Theme](Examples/PluginExample/Sources/PluginExample/Schemas/theme.schema.json) | A theme assembled from shared tokens, with body/heading typography and optional corner radius |
| [App settings](Examples/PluginExample/Sources/PluginExample/Schemas/App/app-settings.schema.json) | Cross-document references for appearance, typography overrides, layout, and recent accent colors |
| [JSON instances](Examples/PluginExample/Sources/PluginExample/Fixtures) | Valid payloads plus invalid colors, missing typography fields, excessive scores, and duplicate colors |

The examples intentionally use canonical `$id` paths that differ from physical
filenames. For example, a nested `typography-style.schema.json` resource lives
inside the shared design-token document; it is not a separate file to download.

Resolution supports:

- Local JSON Pointers, including escaped `/` and `~` tokens and percent-encoded
  fragments.
- Document retrieval URIs and canonical `$id` aliases.
- Nested `$id` resources, which establish new bases for relative references.
- Static `$anchor` names, scoped to their containing resource.
- Relative and absolute references to other explicitly supplied batch documents.

The inline macro's registry contains only its literal. The CLI/plugin registry
contains every schema in the batch. **No reference triggers a network request or
an implicit filesystem read.** A referenced file must be included even if it
already exists beside an input. Relative references use the closest enclosing
`$id`, or the input file's retrieval URI when there is no `$id`.

Annotations and non-structural constraint siblings next to `$ref` retain
conjunction semantics. For example, a referenced `minLength: 3` is not weakened
by a sibling `minLength: 1`. The emitter uses a typed builder component with an
`allOf` validation schema instead of incorrectly merging keyword dictionaries.
Structural siblings (`type`, `properties`, `items`, and `required`) are rejected
for now because they require a separate output-shape composition policy.

Only reachable definitions are emitted. Identifiers and anchors are removed
from inlined copies to avoid registering the same resource repeatedly. Generated
schemas are self-contained, but need not retain the input document's exact shape.

Missing references, duplicate resource IDs/anchors, and cycles are diagnostics
with the original source document and JSON Pointer. Recursive schemas cannot
produce finite tuple outputs and are rejected. Expansion is bounded to 128
levels and 10,000 emitted nodes per schema to prevent pathological reference
graphs from producing unbounded Swift source.

## Command-line generation

```sh
swift run json-schema-codegen --output-directory Generated \
  Schemas/theme.schema.json Schemas/shared.schema.json
```

Generated Swift imports `JSONSchema` and `JSONSchemaBuilder`, and exposes a
namespace such as `ThemeSchema.schema`. Multiple schema inputs are processed in
one invocation. Generation is deterministic and does not embed timestamps.
Unchanged outputs are not rewritten, and schema errors fail the batch before
any output is modified.
All inputs share one reference registry, regardless of command-line order. A
shared schema change therefore regenerates its dependent declarations.

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
Failures are `SchemaGenerationError` values with `pointer`, `message`, and an
optional `documentURI` identifying the original source of a batch failure.

For multi-document generation, provide retrieval URIs explicitly. Results are
returned in the same order as the input documents:

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

The initial implementation supports JSON Schema 2020-12:

| Area | Keywords |
| --- | --- |
| Types | Boolean schemas, `{}`, primitive `type`, one non-null type plus `null` |
| Objects | `properties`, `required`, boolean `additionalProperties`, `minProperties`, `maxProperties` |
| Arrays | Homogeneous `items`, boolean `items`, `minItems`, `maxItems`, `uniqueItems` |
| Strings | `minLength`, `maxLength`, `pattern`, `format` |
| Numbers | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` |
| Values | `enum`, `const` |
| References | `$defs`, non-recursive `$ref`, nested `$id`, static `$anchor`, offline cross-document resolution |
| Annotations | `title`, `description`, `default`, `examples`, `readOnly`, `writeOnly`, `deprecated`, `$comment` |
| Metadata | `$id`, `$schema` for the 2020-12 dialect |

Type-specific keywords require an explicit compatible `type`. Required
properties must be declared in `properties`. Numeric representation follows
`OrderedJSON` (`Int`/`Double`); arbitrary-precision JSON numbers are not provided.
Defaults are annotations, not automatic value insertion.

**Unsupported keywords in reachable schemas are errors**, including input
composition (`allOf`, `anyOf`, `oneOf`), dynamic references, tuple arrays,
schema-valued additional properties, and custom extension keywords.
Output-shape composition and an OpenAPI 3.1 adapter remain follow-on work in
[the original plan](schema-macro-plan.md).

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
