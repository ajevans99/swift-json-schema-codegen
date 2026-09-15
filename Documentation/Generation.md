# Generation guide

This guide covers the development version on `main`. Start with the
[README](../README.md) for installation and a working inline-schema example.

## CLI

Run `swift run json-schema-codegen` from a checkout of this repository, or build
the executable with `swift build -c release --product json-schema-codegen`.

```sh
swift run json-schema-codegen \
  --output-directory Generated \
  --output-style models \
  Schemas/theme.schema.json Schemas/shared.schema.json
```

| Option | Purpose | Default |
| --- | --- | --- |
| `--output-directory <directory>` | Where to write generated Swift | Required |
| `--output-style tuples\|models` | Swift output representation | `tuples` |
| `--recursive-objects value-types\|immutable-classes` | Storage policy for recursive models | `value-types` |
| `--config <file>` | Read a versioned JSON configuration | None |
| `--help` | Show usage | |

At least one input is required. Each file must end in `.schema.json`, with a
basename starting with an ASCII letter and containing letters, digits, or single
`-` or `_` word separators. For example, `user-score.schema.json` produces
`UserScoreSchema.generated.swift` containing `public enum UserScoreSchema`.
Names that collide, including case-insensitive collisions, are errors.

Inputs share a reference registry regardless of argument order. Output is
deterministic, unchanged files are not rewritten, and schema errors fail the
batch before generated files are changed. Quote paths containing spaces; use
`--` before inputs that could otherwise be interpreted as options.

## Configuration

The CLI reads the file passed to `--config`. The build plugin reads
`json-schema-codegen.json` directly inside its target directory.

```json
{
  "version": 1,
  "output": "models",
  "recursiveObjects": "valueTypes",
  "typeNames": {
    "Schemas/common.schema.json#/$defs/Typography": "Typography"
  },
  "caseNames": {
    "Schemas/response.schema.json#/oneOf/0": "ready"
  }
}
```

The naming entries above assume those schema locations exist and produce a
model and union case, respectively. Omit the maps if you do not need custom names.

Defaults apply first, then configuration, then explicit CLI flags. Only `version`
is required. Unknown keys, versions, and values are errors. Configuration values
use camelCase (`valueTypes`, `immutableClasses`), while CLI recursion values use
kebab-case.

Immutable-class storage and naming overrides require model output.

The plugin tracks both schemas and configuration as build inputs. Exclude
`json-schema-codegen.json` from the target's sources to avoid a SwiftPM warning;
the plugin still reads it. Configuration is per target, and generated Swift
is written to SwiftPM's derived-source directory.

### Custom type and case names

Naming overrides require model output. `typeNames` selects a generated type;
`caseNames` selects a union branch, such as `/oneOf/0`, or a string-enum entry,
such as `/enum/1`. The root type name `Value` is fixed.

Selectors use JSON Pointers. In a configuration file, relative document paths
resolve from the configuration directory. Absolute retrieval URIs and canonical
`$id` values also work. Fragment-only selectors such as `#/properties/status`
are allowed when exactly one root is emitted. Escape `/` as `~1` and `~` as `~0`
inside pointer tokens.

The inline macro accepts the same maps as literal arguments:

```swift
import JSONSchemaCodegen

@Schema(
  """
  {
    "type": "object",
    "properties": {
      "status": { "type": "string", "enum": ["draft", "in-progress", "done"] }
    },
    "required": ["status"]
  }
  """,
  output: .models,
  typeNames: ["#/properties/status": "Status"],
  caseNames: ["#/properties/status/enum/1": "working"]
)
enum TaskSchema {}
```

The macro does not read configuration files. All options must be literal syntax.
Overrides must be valid, nonreserved ASCII Swift identifiers. Conflicting,
ambiguous, or unused overrides are errors rather than silently ignored settings.
String-enum indices refer to the original schema array, including duplicates.

## References

Use `$defs` and `$ref` for reusable definitions. The macro resolves references
within its literal; the CLI and plugin resolve across every document in their
batch. Neither downloads schemas nor discovers additional files through `$ref`.

Resolution supports JSON Pointers, `$id`, `$anchor`, `$dynamicAnchor`, and
`$dynamicRef`, including recursive references. Relative references use the nearest
enclosing `$id`, or the input's retrieval URI when no `$id` is present. Nested
`$id` values establish new resource bases; they need not correspond to files.

Constraints beside `$ref` apply in addition to the referenced schema. Missing
references, duplicate IDs or anchors, and cycles that make no progress through
an instance (such as a schema containing only `{"$ref":"#"}`) are generation
errors. References must point to schema locations, not arbitrary annotation data.

Dynamic references are resolved for the entry point's dynamic scope. The result
is self-contained; moving generated components into an unrelated resource does
not retarget those references.

## Core API

Add the `JSONSchemaCodegenCore` product to build a custom generation tool:

```swift
import JSONSchemaCodegenCore

let generator = SchemaGenerator(options: .init(output: .models))
let generated = try generator.generate(#"{"type":"object"}"#)

print(generated.outputType) // Value
print(generated.expression)
print(generated.declarations)
```

`GeneratedSchema` contains a source `expression`, its `outputType`, and supporting
`declarations`. Emit **all declarations inside the same namespace** as the
`schema` member, with `JSONSchema` and `JSONSchemaBuilder` imported. Declarations
may contain models, enums, or static helpers.

For cross-document references, pass an array of `SchemaDocument` values with
retrieval URIs to `generate(_:)`; results follow input order. To emit only one
entry point, use `generate(document, referencing: otherDocuments)`. For file-backed
inputs, supply a stable `logicalName` to keep naming independent of the checkout
path. The CLI and plugin do this automatically.

The core performs no file or network I/O. Failures are `SchemaGenerationError`
values with a `pointer`, `message`, and optional `documentURI`. SwiftSyntax is
used during generation, not at runtime by the generated schemas.

### OpenAPI components

`OpenAPISchemaGenerator` accepts OpenAPI 3.1 JSON documents and generates their
`components.schemas`, preserving component names and order:

```swift
import Foundation
import JSONSchemaCodegenCore

let url = URL(fileURLWithPath: "style-api.openapi.json")
let components = try OpenAPISchemaGenerator(options: .init(output: .models))
  .generateComponents(
    in: SchemaDocument(
      source: try String(contentsOf: url, encoding: .utf8),
      retrievalURI: url
    )
  )
```

The adapter supports the OAS 3.1 base dialect and JSON Schema 2020-12. It does
not support YAML, OpenAPI 3.0, external documents, custom dialects, or inline
operation schemas. OpenAPI `discriminator` and legacy `nullable` are annotations,
not validation or naming instructions. See the
[OpenAPI example](../Examples/OpenAPIExample) for a complete emitter and consumer.

### Shared models and encoding

Use `generateShared(document:schemaPointers:rootNames:)` when multiple entry
points need to share model types in one namespace. Unlike separate `generate`
calls, this API shares types for references to the same schema and emits
functions that map model values back to `JSONValue`. It always uses named models.

See [shared schemas and encoding](SharedSchemas.md) for integration details.
Encoding is not `Codable` synthesis, serialization, or schema validation, and it
cannot recover fields discarded during parsing.
