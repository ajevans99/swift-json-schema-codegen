# Output types and schema support

This guide describes the development version on `main`. See the
[README](../README.md) for installation.

## Output types

Tuple output is the default. Use `output: .models` in the macro,
`--output-style models` in the CLI, or `"output": "models"` in plugin
configuration to generate named types.

| Schema | Tuple output | Model output |
| --- | --- | --- |
| `string`, `integer`, `number`, `boolean` | `String`, `Int`, `Double`, `Bool` | Same |
| `null` | `Void` | Same |
| Boolean schema or unconstrained `{}` | `JSONValue` | Same |
| Homogeneous array | Array of the item's output type | Same, with named models for object items |
| Array with `prefixItems` | `[JSONValue]` | Same |
| Object with multiple properties | Labeled tuple | Immutable `Sendable` struct |
| Object with one property | That property's value | Immutable `Sendable` struct |
| Object with no declared properties | `Void` | Immutable `Sendable` struct |
| Schema-valued `additionalProperties`, no named fields | Typed dictionary | Typed dictionary |
| Named fields and schema-valued `additionalProperties` | `(properties: ..., additionalProperties: ...)` | Model fields plus an `additionalProperties` dictionary |
| `type: ["string", "null"]` | `String?` | Same |
| Heterogeneous union | Generated enum with numbered cases | Generated enum with semantic case names where available |
| `string` with finite `enum` | `String` | Typed string enum |

In model mode, the root is accessible as `Namespace.Value`, either a nominal
type or a type alias. Nested objects also receive names. Object fields are
immutable and have explicit initializers. Models do not automatically conform
to `Codable`, `Equatable`, or `Hashable`; string enums are the exception for
equality and hashing.

Swift property names are normalized and disambiguated without changing the
original JSON keys. Required names without a declared property schema become
`JSONValue` fields. Pattern properties are validated but do not add typed fields.
Schema-valued additional properties produce a dictionary excluding declared and
pattern-matched names; boolean additional-properties schemas add no dictionary.

### Missing values and null

Property presence is separate from value nullability:

| String property | Swift type | Meaning |
| --- | --- | --- |
| Required, nonnullable | `String` | Must be present with a string value |
| Optional, nonnullable | `String?` | `nil` means absent |
| Required, nullable | `String?` | Must be present; `nil` means JSON null |
| Optional, nullable | `String??` | `nil` means absent; `.some(nil)` means JSON null |

Only optional fields default to `nil` in model initializers. A required nullable
field still needs an argument. Initializers do not enforce schema constraints.
The schema's `default` keyword is an annotation, not automatic value insertion.

### String enums

In model mode, finite string enums expose cases and raw-value conversion:

```swift
import JSONSchemaCodegen

@Schema(
  #"{"type":"string","enum":["draft","in-progress","done"]}"#,
  output: .models
)
enum StatusSchema {}

let status: StatusSchema.Value = .inProgress
print(status.rawValue) // in-progress
let restored = StatusSchema.Value(rawValue: "in-progress") // .some(.inProgress)
let unknown = StatusSchema.Value(rawValue: "unknown") // nil
```

These enums conform to `RawRepresentable`, `Sendable`, and `Hashable`. Equality,
hashing, and conversion compare exact Unicode scalars, matching JSON rather than
Swift's canonically equivalent string comparison.

The enum must contain at least one string and no values other than strings or
null, with a compatible type if one is declared. Numeric, boolean, empty,
null-only, mixed non-string, and const-only constraints do not generate string
enums. Additional constraints may reject a case accepted by the raw-value
initializer; use `parseAndValidate` to enforce the whole schema.

## Composition

| Keyword | Behavior |
| --- | --- |
| `allOf` | Intersects types and combines compatible object fields; a field required by any branch is required in the output |
| `anyOf` | Uses a common output type or a generated enum; returns the first schema-valid, successfully parsed branch in schema order |
| `oneOf` | Uses a common output type or a generated enum; validation requires exactly one matching branch |
| `not` | Keeps the surrounding output type, or `JSONValue` if unconstrained, while rejecting matching instances |

Each branch still validates independently. In particular, `allOf` cannot extend
an object that rejects the new fields with `additionalProperties: false`.

Tuple-mode union cases are `.option1`, `.option2`, and so on, in branch order.
Model mode uses custom names, distinct required discriminator constants,
referenced definition names, or JSON kinds when they provide unambiguous names.
Reordering branches can change the generated API and `anyOf` selection.

References to one definition can share its model within a namespace. Separate
definitions remain distinct even if their fields match. Independently generated
namespaces do not share declarations; use the
[shared-root API](SharedSchemas.md) when that is required.

## Recursion

Tuple mode represents recursive references with indirect `ReferenceN` enums.
Unwrap their `.value` case to access the typed payload.

Model mode exposes models directly. Recursive arrays and dictionaries can use
structs, and recursive unions become indirect where necessary. A direct object
cycle such as `Node.next: Node?` cannot be stored as a Swift struct. Generation
reports an error unless you explicitly allow immutable classes:

```swift
import JSONSchemaCodegen

@Schema(
  """
  {
    "type": "object",
    "properties": { "next": { "$ref": "#" } }
  }
  """,
  output: .models,
  recursiveObjects: .immutableClasses
)
enum NodeSchema {}
```

This changes the affected objects to final immutable `Sendable` classes, giving
them reference semantics. Unrelated objects and collection-only recursive
models remain structs.

Container-only cycles, such as an array containing itself with no intervening
model, cannot be recursive Swift type aliases. Model mode rejects these even
with the class policy; tuple mode remains available.

## Validation coverage

Call **`parseAndValidate`** to convert JSON and enforce the complete schema.
`parse` alone does not check every constraint. Validation uses the
[`swift-json-schema` runtime](https://github.com/ajevans99/swift-json-schema).

The generator supports the following JSON Schema 2020-12 keywords:

| Area | Keywords |
| --- | --- |
| Types and values | Boolean schemas, `type` (including arrays), `enum`, `const` |
| Objects | `properties`, `required`, `additionalProperties`, `patternProperties`, `propertyNames`, `dependentRequired`, `dependentSchemas`, `minProperties`, `maxProperties`, `unevaluatedProperties` |
| Arrays | `items`, `prefixItems`, `contains`, `minContains`, `maxContains`, `minItems`, `maxItems`, `uniqueItems`, `unevaluatedItems` |
| Strings | `minLength`, `maxLength`, `pattern`, `format` |
| Numbers | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf` |
| References | `$defs`, `$ref`, `$dynamicRef`, `$id`, `$anchor`, `$dynamicAnchor` |
| Composition | `allOf`, `anyOf`, `oneOf`, `not`, `if`, `then`, `else` |
| Metadata | `$schema` for 2020-12; `$vocabulary` for its seven standard vocabularies |

Annotations such as `title`, `description`, `default`, `examples`, `readOnly`,
`writeOnly`, and `deprecated` are retained. Content keywords are also annotations:
they do not trigger decoding or content validation. Unknown extension keywords
are retained without interpreting arbitrary nested objects as schemas.

Type-specific keywords only constrain applicable instances. For example,
`minLength` without `type` does not require a string. Some constraints affect
validation without changing the Swift output: `prefixItems` validates array
positions but still returns `[JSONValue]`, and pattern properties do not become
model fields. Parsing can therefore discard information.

### Limits

- Custom `$schema` dialects and unknown required vocabularies are errors.
  Unknown optional vocabularies are retained.
- References resolve only within explicitly supplied documents. See
  [reference resolution](Generation.md#references) for scope and URI rules.
- Generation is limited to 128 levels of nesting and 10,000 emitted nodes per
  schema.
- Typed integers and count/length arguments must fit in Swift `Int`. Typed
  `Double` values can round, but overflow and nonzero underflow are rejected.
  `JSONValue` can preserve exact number literals outside those ranges.
- `format` validation depends on the runtime's dialect and validation context;
  content keywords are not assertions.

Support for these keywords is not a claim of full specification conformance.
The [conformance harness](../Tests/Conformance) documents measured coverage and
known failures against the official test suite, including unsupported dialects.
