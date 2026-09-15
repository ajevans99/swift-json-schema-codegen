# Swift JSON Schema Codegen

[![CI](https://github.com/ajevans99/swift-json-schema-codegen/actions/workflows/ci.yml/badge.svg)](https://github.com/ajevans99/swift-json-schema-codegen/actions/workflows/ci.yml)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fajevans99%2Fswift-json-schema-codegen%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ajevans99/swift-json-schema-codegen)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fajevans99%2Fswift-json-schema-codegen%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ajevans99/swift-json-schema-codegen)

Turn JSON Schema documents into typed
[JSONSchemaBuilder](https://github.com/ajevans99/swift-json-schema) expressions.
Use `@Schema` for inline schemas, or generate Swift from schema files with the
command-line tool or SwiftPM build plugin.

Generated components parse and validate JSON into Swift values: primitives,
labeled tuples, arrays, and enums, with opt-in named immutable models.
Generation does not synthesize `Codable` conformance.

For OpenAPI operation clients, see the separate
[Swift OpenAPI Schema Codegen](https://github.com/ajevans99/swift-openapi-schema-codegen)
package. OpenAPI document and HTTP policies are not part of this package's
generic model generation.

## Requirements

Swift 6.1 or later. Supports macOS 14, iOS 17, tvOS 17, watchOS 10,
Mac Catalyst 17, visionOS 1, and later. The CLI and generation core also support Linux.

The package requires `swift-json-schema` **0.14.0 or later**, which includes
`JSONComponents.Projection` and the parsing fixes needed by generated schemas.
SwiftPM resolves the published runtime automatically; no local checkout is
required.

For upstream runtime development only, a local checkout can be selected explicitly:

```sh
export JSON_SCHEMA_RUNTIME_PATH=/path/to/swift-json-schema
swift package edit swift-json-schema --path "$JSON_SCHEMA_RUNTIME_PATH"
```

The smoke scripts recognize this environment variable or the root package's
editable `Packages/swift-json-schema` link. To return to the released runtime,
unset the variable and run `swift package unedit swift-json-schema` in every
package where edit mode was enabled, then resolve again.

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

### Default tuple output

| Schema | Swift output |
| --- | --- |
| `string` | `String` |
| `integer` | `Int` |
| `number` | `Double` |
| `boolean` | `Bool` |
| `null` | `Void` |
| Boolean schema or unconstrained `{}` | `JSONValue` |
| Homogeneous array | `[Item.Output]` |
| Array with `prefixItems` | `[JSONValue]`; prefix and tail constraints are validated separately |
| Object with two or more properties | Labeled tuple in schema property order |
| Object with one property | The property's value, unwrapped |
| Object with no declared properties | `Void` |
| `type: ["string", "null"]` | `String?` |
| General `type` array | Generated typed `UnionN` enum |
| Object with schema-valued `additionalProperties`, no named fields | `[String: Additional.Output]` |
| Named fields plus schema-valued `additionalProperties` | `(properties: ExistingOutput, additionalProperties: [String: Additional.Output])` |
| Recursive reference | Generated indirect `ReferenceN` enum with a `.value(Target.Output)` case |

Property presence and nullability are separate. An optional nullable string is
`String??`: `nil` means absent, and `.some(nil)` means explicitly null. A required
nullable property must be present.

Object property names become collision-safe ASCII Swift labels; existing valid
identifiers are preserved and keywords such as `class` are escaped automatically.
Runs of punctuation or non-ASCII characters between identifier characters become
`_`, leading and trailing such characters are dropped, leading digits gain `_`,
and empty labels or `_` become `property`. Collisions gain `_2`, `_3`, and so on in
property order, with existing valid identifiers reserved first. For example,
`$id` and `id` become `id_2` and `id`. JSON keys and validation are unchanged.
Schema-valued additional properties are included in a typed dictionary, excluding
declared and pattern-matched names. Boolean additional-properties schemas preserve
the existing named-field output. Pattern properties remain validation-only and
do not add fields to the tuple. Required names without a declared property schema
become `JSONValue` fields; they do not count as evaluated by `properties`.

Call `parseAndValidate` to parse a value and enforce its schema constraints.
`parse` alone performs typed conversion without checking every keyword.
`format` validation follows `swift-json-schema`'s dialect and validation context.

### Named models

Opt into `output: .models` to expose the complete result as `Namespace.Value`:

```swift
@Schema(
  """
  {
    "type": "object",
    "properties": {
      "name": {"type": "string"},
      "nickname": {"type": ["string", "null"]},
      "contact": {"type": ["string", "null"]}
    },
    "required": ["name", "nickname"],
    "additionalProperties": false
  }
  """,
  output: .models
)
public enum PersonSchema {}

let person: PersonSchema.Value = try PersonSchema.schema.parseAndValidate(
  instance: #"{"name":"Ada","nickname":null}"#
)
let draft = PersonSchema.Value(name: "Grace", nickname: nil)
// draft.contact defaults to nil (absent); .some(nil) means explicitly null.
```

Object outputs are immutable `Sendable` structs with explicit initializers,
including empty and singleton objects. Nested objects and object-valued array
items/dictionary entries receive named models. Unconstrained primitive and
container roots use a `Value` type alias when no root nominal type is needed.
Mixed objects put their fields directly on the model alongside a typed `additionalProperties`
dictionary; a real field of that name keeps its label and the synthesized
dictionary receives a collision-free suffix.

Initializers construct values; they do **not** enforce schema constraints.
Only absent-capable fields default to `nil`, so a required nullable field still
needs an initializer argument. Models do not automatically conform to `Codable`,
`Equatable`, or `Hashable`, and fields are not mutable. The finite string enums
described below are an exception: they have exact equality and hashing.

Heterogeneous unions use semantic case names when there is reliable evidence:
an explicit override, distinct required discriminator constants, a referenced
definition, or a JSON kind. For example, ready/pending object alternatives can
be consumed as `.ready(payload)` and `.pending(payload)` rather than `.option1`
and `.option2`. Equal-shaped but distinct object definitions remain distinct
models; branches with genuinely common output still collapse. Schema validity
and `anyOf`'s first-valid-branch order do not change.

Type names come from definitions, references, properties, and container roles,
not mutable `title`/`description` prose. Context disambiguation and stable hash
suffixes resolve collisions. Names are scoped to one generated namespace;
separate schema namespaces do not share model declarations.

For recursion, public fields refer to models directly instead of exposing
`ReferenceN.value` adapters. Arrays and dictionaries can hold recursive structs;
natural semantic unions become indirect when necessary. An inline cycle such
as `Node.next: Node?` cannot be a Swift struct. Named mode reports a located
representation error by default; allow immutable reference models explicitly:

```swift
@Schema(
  """
  {
    "type": "object",
    "properties": {"next": {"$ref": "#"}}
  }
  """,
  output: .models,
  recursiveObjects: .immutableClasses
)
enum NodeSchema {}
```

This policy converts only objects in the remaining cyclic layout components
to final immutable `Sendable` classes. Unrelated objects and collection-only
recursive models stay structs. It changes value/reference semantics and is
never enabled implicitly.

Pure container-only recursive aliases, such as an array whose items reference
that same array, have no nominal model boundary and cannot be expressed as a
recursive Swift type alias. Named mode diagnoses these explicitly, including
under the class policy; default tuple mode remains available for those schemas.

The [design-token plugin example](Examples/PluginExample) uses named root values.
The [official meta-schema example](Examples/MetaSchemaExample) demonstrates
recursive `.object`/`.boolean` values and direct nested-schema access.

### Typed string enums

Named output turns finite string `enum` constraints into public, payload-free
Swift enums:

```swift
@Schema(
  #"{"type":"string","enum":["draft","in-progress","done"]}"#,
  output: .models
)
public enum StatusSchema {}

let status: StatusSchema.Value = .inProgress
let jsonString: String = status.rawValue // "in-progress"
let restored = StatusSchema.Value(rawValue: jsonString) // .some(.inProgress)
let unknown = StatusSchema.Value(rawValue: "unknown") // nil
```

These enums conform to `RawRepresentable` with `RawValue == String`, `Sendable`,
and `Hashable` (including `Equatable`). They deliberately do **not** use Swift's
synthesized `enum E: String` implementation: Swift `String` equality considers
canonically equivalent spellings equal, while JSON compares Unicode scalars.
Generated conversion, equality, and hashing preserve that distinction. For
example, `"\u{e9}"` and `"e\u{301}"` receive distinct cases when both are listed;
listing only one does not make `init(rawValue:)` accept the other. Use scalar
or UTF-8 comparison if comparing raw strings with that same exactness.

Case names use the existing ASCII lowerCamelCase allocator (`in-progress` becomes
`inProgress`). Empty/punctuation-only names use `alternative`, leading digits
use that prefix, keywords are escaped, and collisions receive deterministic
FNV-based suffixes derived from the source identity and exact value bytes.
Byte-identical duplicates share one case; duplicate entries and original order
remain in `schemaValue`. The synthesized members `rawValue`, `RawValue`, `hash`,
and `hashValue` are reserved. No `Codable`, JSON encoder, or `CaseIterable`
conformance is generated.

The applicability policy is deliberately bounded:

- An enum must contain at least one string, with all other entries strings or
  null. An explicit string/nullable-string type is honored; without a type the
  finite enum supplies the string/null parsing domain.
- Nullable strings use `Enum?`; optional nullable object fields still use
  `Enum??`, preserving absent versus explicitly null. Enum models work as root
  `Value`, object fields, array/dictionary entries, references, and union payloads.
- `allOf` and reference refinements retain the first positive pure string-enum
  bound through the existing intersection planner. They do not solve
  satisfiability or remove cases excluded by other `enum`, `const`, pattern, or
  conditional constraints. Construction/raw conversion checks membership in
  this finite bound; **`parseAndValidate` enforces the complete schema**.
- `anyOf`/`oneOf` keep their existing branch order, validity, and nominal
  common-output rules. Applicable branches get enum payloads; an unconstrained
  string alternative remains `String`. General `type` arrays also retain their
  semantic union, with a typed string branch where applicable. Values from
  alternative or conditional branches are never incorrectly treated as a
  conjunctive bound.
- Empty enums, null-only enums, mixed non-string enums, const-only schemas, and
  unconstrained strings retain their previous representation. Numeric/boolean
  enums are not introduced. Default tuple output is unchanged.

Unrefined references share enum models; separate definitions remain nominally
distinct, even with identical values. Enum-valued reference siblings specialize
the model just like other output-shape refinements; validation-only constraints
such as `const` and `pattern` can reuse the base enum. Type naming and recursion
use the same model graph as objects and unions.

Use `typeNames: ["#/properties/status": "Status"]` for a nested enum name and
`caseNames: ["#/properties/status/enum/1": "working"]` for a case. Selectors address
the original enum array indices (including duplicate entries); contradictory
names for the same deduplicated case fail explicitly. In compositions, target
the enum-bearing conjunct's pointer: matching values carry their original indices
from each positive enum constraint, even when a refinement reorders the values.
A refinement entry outside the chosen bound has no emitted case and is diagnosed.
CLI configuration, target-local plugin configuration, and OpenAPI component
selectors accept the same overrides.

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
- `$dynamicAnchor` and `$dynamicRef`, including recursive dynamic scope overrides.
- Relative and absolute references to other explicitly supplied batch documents.

The macro resolves references within its literal. The CLI and plugin resolve
references across all files in a batch. Referenced files must be included in the
batch; the generator does not fetch URLs or read files implicitly.

Relative references use the nearest enclosing `$id`, or the input file's URI
when no `$id` is present. An `$id` can identify an embedded schema rather than a
file: the example's `typography-style.schema.json` resource is defined inside
the shared design-token document.

Constraints alongside `$ref` apply in addition to the referenced schema.
Validation preserves conjunction boundaries and annotation scope: sibling
`unevaluatedProperties` and `unevaluatedItems` can consume referenced annotations,
without opening a closed object inside a referenced schema.

In default tuple mode, acyclic references are inlined. Recursive targets become indirect `Reference1`,
`Reference2`, ... enums and lazy `JSONReference` components backed by local
definitions. Unwrap `.value` to access a recursive child's typed payload.
Dynamic references are specialized for the entry point's outer dynamic scope;
the result is a self-contained static bundle, not a schema that can be dynamically
retargeted by moving it into an unrelated resource after generation.

Missing references, duplicate IDs or anchors, and cycles that make no instance
progress (such as a schema containing only `{"$ref":"#"}`) produce errors with
the source document and JSON Pointer.

### Official JSON meta-schema example

[Examples/MetaSchemaExample](Examples/MetaSchemaExample) builds the unmodified
official 2020-12 meta-schema and all seven vocabulary meta-schemas with the
build-tool plugin. The fixtures, provenance, checksums, and license are checked
in, so reference resolution is offline. The executable validates schemas,
rejects malformed schemas, and validates the official documents themselves.

```sh
bash Tests/MetaSchema/smoke.sh
```

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
for the [supported keywords](#json-schema-coverage-and-limits). YAML, OpenAPI 3.0, external
documents, and custom dialects are not supported. OpenAPI-only keywords such as
`discriminator`, and legacy `nullable`, are preserved as annotations rather than
interpreted as validation or code-generation instructions.

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

Run `swift run json-schema-codegen --help` (or `-h`) for usage. The CLI uses
Apple's [Swift Argument Parser](https://github.com/apple/swift-argument-parser)
for help and diagnostics. `--output-directory` and at least one input are required.
Options may appear between input paths; use `--` to treat all remaining arguments
as literal input paths (including paths beginning with `-`). Filename rules still
apply. Quote paths containing spaces, and use `--output-directory=-generated` for a
directory beginning with `-`. The `--output-directory=Generated` form is also
accepted. Repeating `--output-directory` uses the last value, rather than the
previous duplicate-option error.

Select named output with `--output-style models`. Use
`--recursive-objects immutable-classes` only when reference models are acceptable.
The defaults remain `tuples` and `value-types`.

For reusable options and explicit names, pass `--config path/to/config.json`:

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

Precedence is **defaults < configuration < explicitly provided flags**.
Configuration enum values use camelCase; CLI recursion values use kebab-case.
Unknown keys, versions, and values are errors. Relative selectors resolve from
the configuration file's directory; absolute retrieval URIs and canonical IDs
are also supported. Fragment-only selectors are allowed for a single emitted
root. Use JSON Pointer escaping for literal `/` and `~` characters in keys.

Type and case overrides target declarations/cases actually emitted by named
mode. Cases can be union branches (`/oneOf/0`) or string-enum entries (`/enum/0`).
Invalid, reserved, conflicting, ambiguous, and unused names fail explicitly,
rather than silently reverting to numbered names. The root name `Value` is fixed.
For inline schemas, the same maps are literal `typeNames:` and `caseNames:`
arguments to `@Schema`; the macro does not read configuration files.

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

To opt a target into named models, place `json-schema-codegen.json` directly in
the target directory:

```json
{"version": 1, "output": "models"}
```

The plugin tracks this file as a build input, so changing options regenerates
the derived Swift. Add `exclude: ["json-schema-codegen.json"]` to the target to
avoid an unhandled-file warning; the plugin still discovers the configuration.
Configuration is target-local, not a package-wide or machine-specific setting.

See [Examples/PluginExample](Examples/PluginExample) for a complete package.

## Shared core

Use `JSONSchemaCodegenCore` to build your own generation tools:

```swift
import JSONSchemaCodegenCore

let generated = try SchemaGenerator().generate(#"{"type":"string","minLength":1}"#)
print(generated.expression)
print(generated.outputType) // String
```

All core entry points accept the same options:

```swift
let generator = SchemaGenerator(
  options: .init(output: .models, recursiveObjects: .immutableClasses)
)
let generated = try generator.generate(#"{"type":"object"}"#)
print(generated.outputType) // Value

let openAPI = OpenAPISchemaGenerator(options: .init(output: .models))
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
    retrievalURI: url,
    logicalName: "Schemas/" + name
  )
}
let generated = try SchemaGenerator().generate(inputs)
```

To emit only an entry point while making other documents available for reference
resolution, use `generate(document, referencing: otherDocuments)`.
For file-backed core inputs, a stable `logicalName` provides portable naming
context without encoding a developer's checkout directory. The CLI and plugin
provide this context automatically.

### Shared roots and model encoding

For multiple typed entry points in one namespace, opt into
`generateShared(document:schemaPointers:rootNames:)`. It returns common
`declarations` and ordered `roots`, each exposing `name`, `outputType`,
`expression`, and `encodingExpression`. Root aliases and static
`encode<RootName>(_:) throws -> JSONValue` functions are included.

This API always uses named models and shares nominal types by canonical schema
identity and specialization—not by structural equality. A list item and a
retrieve/create root referencing the same model are directly interchangeable.
It accepts schema pointers in any raw JSON container; OpenAPI normalization
remains an integration concern.
Schemas with object keywords but no explicit type expose typed `.object`
payloads plus a disjoint `.nonObject(JSONValue)` case without narrowing their
original validation schema.

Encoding preserves modeled field names, absence versus null, semantic unions,
Unicode string enums, and exact `JSONValue` number literals. Typed extra keys
that collide with modeled fields throw; nonfinite `Double` values throw.
No `Codable` conformance or new runtime dependency is generated. Existing
single-root/default APIs are unchanged.
See [Shared schemas and encoding](Documentation/SharedSchemas.md) for the full
integration contract, limitations, and compiled cross-module verification.

## JSON Schema coverage and limits

The package supports these JSON Schema 2020-12 keywords:

| Area | Keywords |
| --- | --- |
| Types | Boolean schemas, `{}`, primitive `type`, general type arrays (nullable pairs retain optional output) |
| Objects | `properties`, `required`, schema-valued and boolean `additionalProperties`, `patternProperties`, `propertyNames`, `dependentRequired`, `dependentSchemas`, `minProperties`, `maxProperties`, `unevaluatedProperties` |
| Arrays | `items`, `prefixItems`, `contains`, `minContains`, `maxContains`, `minItems`, `maxItems`, `uniqueItems`, `unevaluatedItems` |
| Strings | `minLength`, `maxLength`, `pattern`, `format` |
| Numbers | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` |
| Values | `enum`, `const` |
| References | `$defs`, `$ref`, `$dynamicRef`, nested `$id`, `$anchor`, `$dynamicAnchor`, recursive schemas, offline cross-document resolution |
| Composition | `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, including same-output and generated-enum unions |
| Annotations | `title`, `description`, `default`, `examples`, `readOnly`, `writeOnly`, `deprecated`, `$comment`, `contentEncoding`, `contentMediaType`, `contentSchema`, unknown extension keywords |
| Metadata | `$id`, `$schema` for the 2020-12 dialect, `$vocabulary` for the default dialect's seven standard vocabularies |

Type-specific keywords constrain only applicable instances: `minLength` without
`type` does not imply a string type, and `minimum` alongside `type: "string"`
does not reject strings. Unconstrained projections use `JSONValue`, while retaining
the complete validation definition. `enum` may be empty or contain duplicate
values; an empty enum accepts no instances. Schema literals and numeric assertions
use `OrderedJSON`'s exact `JSONNumberLiteral` representation when Swift numeric
literals would lose precision or range. Typed outputs remain `Int`/`Double`;
unconstrained `JSONValue` outputs can preserve numbers outside those ranges.
Defaults are annotations, not automatic value insertion.

Unknown extension keywords are retained as annotations without interpreting
arbitrary nested objects as schemas. Unknown required vocabularies are explicit
errors; unknown optional vocabularies are retained. Content keywords are
annotations, not automatic decoding or content validation. Arrays with
`prefixItems` intentionally expose `[JSONValue]`; the `items` schema applies only
to the tail, never to the prefix during typed parsing.

Custom `$schema` dialects and unknown required vocabularies are not implemented;
they fail explicitly rather than silently enabling or ignoring assertions.
References must target standard schema-bearing locations, not arbitrary
annotation data. Generation is limited to 128 levels of nesting and 10,000
emitted nodes per schema. Count/length keyword arguments and typed integer output
are limited to Swift `Int`, even when a larger mathematical integer passes schema
validation. Typed `Double` parsing permits ordinary binary rounding but rejects
overflow and nonzero underflow.

This is not a claim of unrestricted specification conformance. The
[generated-code conformance harness](Tests/Conformance) compiles official
2020-12 test cases and compares both validation and parsing results; unsupported
groups remain reported failures. Optional formats depend on runtime configuration.

## Development

```sh
swift test
bash Tests/CLI/smoke.sh
bash Tests/OpenAPI/smoke.sh
bash Tests/MetaSchema/smoke.sh
bash Tests/NamedModels/smoke.sh
bash Tests/NamedModels/entry-points.sh
bash Tests/Conformance/run.sh
bash Tests/Conformance/run.sh --compare-models --recursive-objects immutable-classes
```

The smoke scripts generate Swift, then build and run the plugin and OpenAPI
example consumers. The conformance run also needs a local official test-suite
checkout; see its README for setup and current coverage.

### Core source organization

`Sources/JSONSchemaCodegenCore/` keeps the public schema document, generator,
OpenAPI adapter, and configuration re-export at its root. Internal implementation
files are grouped by responsibility:

| Directory | Responsibility |
| --- | --- |
| `Planning/` | Reference resolution, parsing decisions, and the `SchemaEmitter` generation coordinator |
| `Models/` | Semantic output identities, model definitions, symbol allocation, and recursive storage layout |
| `Naming/` | Identifier normalization, collision rules, and naming requests |
| `Syntax/` | Swift types, expressions, model declarations, and recursive adapters |

These directories belong to one SwiftPM target, not separate modules or enforced
dependency layers. `SchemaGenerator` remains the public facade; `SchemaEmitter`
coordinates planning and syntax emission internally, with private state and
helpers. Public options remain in `JSONSchemaCodegenConfiguration`.

## License

MIT. See [LICENSE](LICENSE).
