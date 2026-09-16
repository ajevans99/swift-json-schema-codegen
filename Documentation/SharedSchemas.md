# Shared schema roots and model-to-JSON mapping

`SchemaGenerator.generateShared(document:schemaPointers:rootNames:)` is an
opt-in core API for integrations that need multiple typed entry points in one
Swift namespace. It always uses named models, independently of `options.output`.
The existing `generate` APIs, macro, CLI, and default tuple representation are
unchanged.

```swift
let generated = try SchemaGenerator().generateShared(
  document: SchemaDocument(
    source: source,
    retrievalURI: URL(string: "https://example.com/container.json")!
  ),
  schemaPointers: [
    "/responses/retrieve",
    "/responses/list",
    "/requests/create"
  ],
  rootNames: ["Retrieve", "List", "Create"]
)
```

The input can be any JSON container with schema objects/booleans at the selected
JSON Pointers. Array-index and escaped pointer tokens are supported; `""` selects
the whole document. This API does not interpret OpenAPI operations or normalize
OpenAPI schemas. That work belongs to the integrating layer.

Selected schemas are indexed before resolving any references. JSON Pointer
references into the container register their target schema and schema-bearing
descendants on demand. `$id`, static anchors, and dynamic anchors use the existing
resolver; an identifier/anchor target must already belong to a selected or
discovered schema. Arbitrary container objects are not scanned for identifiers,
and references never perform file/network I/O.

## Result and integration

`GeneratedSharedSchemas` has:

- `declarations: [String]`: common public models, private parser/encoding helpers,
  public root type aliases, and public static encoding functions.
- `roots: [GeneratedSharedSchemaRoot]`: one entry per input pointer, in input
  order, exposing `name`, `outputType`, `expression`, and `encodingExpression`.

`outputType` is the root's public alias. `expression` is its
`JSONSchemaBuilder` parser expression. `encodingExpression` is a throwing static
function reference, such as `Self.encodeCreate`, with type
`(Create) throws -> JSONValue`.

Place all declarations **once**, and all expressions in the same enclosing type,
with `JSONSchema` and `JSONSchemaBuilder` imported:

```swift
public enum APIModels {
  // generated.declarations, including:
  // public struct Model: Sendable { ... }
  // public typealias Retrieve = Model
  // public typealias List = [Model]
  // public typealias Create = Model
  // public static func encodeCreate(_ value: Create) throws -> JSONValue { ... }

  public static var retrieve: some JSONSchemaComponent<Retrieve> {
    // generated.roots[0].expression
  }
}
```

Root names must be unique, nonreserved ASCII Swift identifiers. Their generated
`encode<RootName>` names are reserved too. The shared allocator reserves all root
aliases before allocating models. Choose an enclosing namespace and additional
wrapper members that do not collide with the generated public declarations.
An empty batch returns empty declarations and roots; mismatched counts are errors.

Shared-mode validation definitions larger than 4 KiB use private immutable
constants instead of one Swift syntax subtree per JSON scalar. Generation checks
an exact serialized-byte round trip with OrderedJSON; the generated constant
uses the existing `JSONValue.parse` once on first access and explicitly traps
if its generator-authored payload is corrupted. The complete `SchemaValue`,
including reference annotation scope, remains unchanged. This does not replace
typed models with raw JSON or parse schema text on each request. Smaller literals
and existing single-root/default output retain their previous representation.

Oversized shared parser expressions are split structurally into private
functions returning `some JSONSchemaComponent<ExactOutput>`. Each completed
fragment gets its own factory; factories are not deduplicated by model name or
schema equality. This bounds nested compiler constraint trees without changing
the parser, validation definition, reference scope, or public model identities.
The size check examines only a bounded token prefix. Small shared expressions
and existing single-root/default output remain inline.

## Preserving unmodeled object properties

The default remains a schema-directed projection: modeled properties and
schema-valued `additionalProperties` are retained, but other allowed keys are
discarded. In particular, omitting `additionalProperties` or setting it to
`true` does not enable storage by itself.

Programmatic shared/named generation can opt in for the entire namespace:

```swift
let generator = SchemaGenerator(options: .init(unknownProperties: .preserve))
let shared = try generator.generateShared(
  document: document, schemaPointers: pointers, rootNames: names)
```

`SchemaGenerationOptions.unknownProperties` defaults to `.discard`; `.preserve`
requires named output for single-root generation. Existing macro and CLI
defaults are unchanged. The policy adds `unmodeledProperties: [String: JSONValue]`
with an empty initializer default. Schema-declared name collisions receive a
deterministic suffix such as `unmodeledProperties_2`.

Typed `additionalProperties` retain their separate typed storage. The new
dictionary stores only keys not already represented by modeled fields or typed
extras, including pattern-matched keys without modeled fields. Pure typed
dictionaries remain dictionaries when every key is already captured. Both
dictionaries flatten into the JSON object; conflicting modeled, typed-extra,
or unmodeled keys throw instead of overwriting data.

An explicit `additionalProperties: false` with no nonempty `patternProperties`
map omits unmodeled storage, including when that closed property set belongs to
a reference or an `allOf` conjunct. Pattern-bearing objects retain storage for
legal pattern-matched keys. This is a bounded property-coverage decision, not
general schema satisfiability or `unevaluatedProperties` inference; other
constraints still require validation.

The private capture adapter preserves its upstream `schemaValue` and parsing
scope; it does not insert `additionalProperties` or change annotation coverage.
Original references, compositions, patterns, and `unevaluatedProperties` still
govern validation. As with other projections, use `parseAndValidate`, and
validate encoded requests before transmission.

Raw unmodeled `JSONValue` values retain exact number tokens and explicit nulls.
This is not a promise that every modeled value round-trips lexically: declared
`number` fields and typed numeric extras still use their existing `Double`
representation and may round decimal values. The opt-in does not change that
numeric policy.

## Sharing and naming

Objects, finite string enums, and semantic unions share nominal types only by
canonical schema identity, including refinement and dynamic-reference
specialization. A list's referenced item and a retrieve/create root referencing
the same schema have the same Swift type. Distinct definitions with equal shapes
remain distinct; shape-changing reference siblings remain specialized.

Annotation-only reference siblings, including repeated descriptions and unknown
metadata, do not specialize a union's referenced payload models. Their complete
original annotations and validation definitions remain attached to each parser.
This also applies inside nullable wrappers and to the existing single-root named
output. Defaults remain annotations rather than supplying missing required
values; discriminator metadata never changes `oneOf` validity.

Names are allocated together from the existing model graph, provenance, and
naming rules. Existing type/case overrides and explicit `.immutableClasses`
recursion policy apply. Unlike single-root named mode, there is no fixed nominal
`Value` model: every root gets its requested alias, and referenced models keep
graph-allocated names. Multiple aliases may refer to the same nominal type.

### Object keywords without an explicit type

In shared mode only, a schema with `properties` or `required` but no explicit
`type` exposes a disjoint object/nonobject representation. For a referenced
`Model`, the typical declaration is:

```swift
public enum Model: Sendable {
  case object(ModelObject)
  case nonObject(JSONValue)
}
```

The object payload has the usual typed fields and initializer. List items and
retrieve roots referencing that schema share this wrapper and payload. Explicit
type overrides select the wrapper; its `properties` location (or `required`
location when no `properties` exists) selects the object payload.

Object keywords alone do not exclude other JSON kinds. A parsing-only
`anyOf` separates the typed object branch from a `not: {type: object}` branch,
and `Projection` retains the complete original validation schema, including
reference-sibling annotation scope. Invalid objects cannot fall through into
raw JSON. Valid arrays, primitives, and null remain accepted. Encoding
`.nonObject` with a JSON object throws instead of bypassing the typed payload.
Construct objects with `.object(.init(...))`.

This bounded representation does not infer a restrictive `type: object` for the
original schema. Finite string enums keep their existing specialized output,
and the existing single-root tuple/named APIs remain unchanged.

## Encoding contract

Encoders map constructed model values to `JSONValue`; they are **not serializers**
and do not synthesize `Codable` or add runtime dependencies. Serialization, HTTP
transport, and schema validation remain the integrating layer's responsibilities.
Initializers and encoders do not enforce all JSON Schema constraints; call the
generated parser's `parseAndValidate` when validation is required.

The mapping preserves all modeled values:

- JSON field names remain the original keys, not Swift property labels.
- Optional nonnullable fields omit outer `nil`.
- Optional nullable `T??` fields omit outer `nil`, emit JSON null for `.some(nil)`,
  and encode the value for `.some(.some(value))`.
- Required nullable fields always emit their key, including JSON null.
- Required-only fields retain their `JSONValue`.
- Typed additional properties are flattened into the object. Any extra key that
  collides with a modeled JSON key throws, **even when that modeled field is
  absent**; no field is silently overwritten. This includes required-only keys,
  which the parser may also project into the extras dictionary. Callers must
  remove that duplicate entry before encoding such a parsed model.
- Semantic union cases encode their selected payload; null cases emit null.
- String enum raw values preserve exact Unicode scalar identity.
- Arrays, dictionaries, nullable roots, recursive models, and dynamic
  specializations are encoded from the same semantic output graph.

`JSONValue` payloads (including prefix-array values and untyped fields) are passed
through without numeric conversion. The published runtime's validated
`JSONNumberLiteral` preserves exact tokens such as `1e400`, `1e-400`, and long
decimals. Ordinary number schemas retain the existing `Double` representation:
finite values encode through the runtime's finite-double constructor; NaN and
infinity throw. Precision already lost by parsing a schema's `Double` projection
cannot be reconstructed. There is no implicit exact-number-to-Double conversion
in an encoder.

Object fields are emitted in modeled order; dictionary/extra keys are sorted for
deterministic output. Schema projections may discard unknown fields or
validation-only pattern properties during parsing. Encoding need not reconstruct
discarded data. Unsupported semantic encoding shapes fail during generation with
a source JSON Pointer rather than emitting an incorrect encoder. Runtime mapping
failures throw a generated private error whose description contains a source
pointer; no public error-type dependency is required.

## Verification

```sh
swift test --filter SharedSchemaGenerationTests
bash Tests/NamedModels/shared-smoke.sh
```

The smoke test generates source, compiles it as a separate library, and consumes
its public aliases and initializers from another module using the published
runtime. It verifies type sharing, constructed requests, all presence/null
states, required-only keys, extras collisions, Unicode enums, exact-number
payloads, finite-number rejection, unions, and recursive/dynamic outputs.
