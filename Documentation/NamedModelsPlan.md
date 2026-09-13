# Named models and meaningful generated names

**Status:** implemented in the working checkout. See section 14 for local
verification, measured costs, and release prerequisites.

**Scope:** add an opt-in representation that produces named Swift structs and
semantic union names while preserving the existing JSON Schema validation engine.
Sections 1–13 retain the approved design and its rationale. This document is not
approval to change defaults, create pull requests, or publish releases.

## 1. Recommended direction

Introduce a named-model layer between parsing-shape planning and SwiftSyntax
emission. Do not try to improve this solely by renaming `Union1` or wrapping the
final root tuple.

The recommended first version has these properties:

- Existing calls continue to generate the current tuple-based representation.
- Named-model mode gives each generated namespace a `Value` root output.
- Object fields use immutable, named models, including singleton objects.
- Existing heterogeneous unions receive names derived from schema structure and
  semantic case labels where the schema supplies enough information.
- Compatible references reuse a model within one generated namespace.
- Runtime reference adapters remain implementation details, not fields or cases
  that application code must unwrap.
- Value types are the default. Generating immutable classes to break unavoidable
  object-layout cycles requires an explicit option.
- Validation, JSON keys, absence/null semantics, and union selection remain
  unchanged.

The first practical milestone is a pleasant API for the existing theme/design
token examples. The official meta-schema remains the integration stress case,
not the only measure of usability.

## 2. Current implementation and the necessary changes

The working checkout already resolves recursive/dynamic references and separates
complete validation schemas from typed parsing projections. That is a useful
foundation, but the current planning and emission stages are intertwined.

The responsibilities below describe the named-model design baseline; source
paths follow the current Core directory layout.

| Current location | Current responsibility | Planned evolution |
| --- | --- | --- |
| `Sources/JSONSchemaCodegenCore/Planning/SchemaReferenceGraph.swift` | Resolves references; builds finite recursive definitions; preserves validation scope | Retain behavior and expose stable provenance/specialization identity for model planning |
| `Sources/JSONSchemaCodegenCore/Planning/SchemaEmitter.swift` | Checks schemas, plans intersections/unions/objects, and emits expressions | Extract a shared semantic parsing plan; select tuple or named-model emission afterward |
| `Sources/JSONSchemaCodegenCore/Models/SchemaOutput.swift` | Describes named types, containers, optionals, and tuples | Distinguish built-in types from references to generated model identities |
| `Sources/JSONSchemaCodegenCore/Syntax/SchemaSyntax.swift` | Builds types, tuple maps, unions, and validation helpers | Add structured model declarations and constructor maps |
| `Sources/JSONSchemaCodegenCore/Syntax/RecursiveSchemaSyntax.swift` | Emits public `ReferenceN` wrappers and lazy factories | Keep the legacy path; add private adapters whose outputs map to public models |
| `Sources/JSONSchemaCodegenCore/Naming/SchemaPropertyNames.swift` | Maps arbitrary JSON keys to collision-safe Swift labels | Preserve this field-label contract; add separate type/case naming rules |
| `Sources/JSONSchemaCodegenMacros/SchemaMacro.swift` | Accepts exactly one literal and emits namespace members | Parse literal representation/naming options and pass namespace context |
| CLI, plugin, and OpenAPI adapter | Select roots, generate namespaces, and manage files | Pass the same validated configuration to the core |

Important current details that the refactor must preserve:

- `objectPlan` deliberately unwraps singleton objects and returns `Void` for
  fieldless objects in legacy mode.
- Declared properties precede undeclared required names in the output.
- Schema-valued additional properties have a separate typed dictionary output.
- `unionNames` currently shares enums by payload-type sequence and assigns
  traversal-based `UnionN` names. That is insufficient for semantic model names.
- Reference resolution specializes by dynamic scope. A raw schema pointer alone
  is not a sufficient model identity.
- `ResolvedSchema.validationValue` preserves reference-sibling annotation scope.
  Model planning must not reconstruct validation by merging object fields.
- The public core result is still `GeneratedSchema(expression:outputType:declarations:)`.
  It can remain source-compatible.

### Dependency prerequisite

The runtime prerequisite is satisfied by `swift-json-schema` **v0.14.0**, released
on September 13, 2026. It includes
[ajevans99/swift-json-schema#184](https://github.com/ajevans99/swift-json-schema/pull/184)
and the `JSONComponents.Projection` API. The codegen manifest now requires
0.14.0 or later; a local editable runtime is no longer a release prerequisite.
Do not fall back to the old schema-value mutation approach.

No additional upstream API is needed for the basic private reference-adapter
approach. An isolated compiled prototype has verified recursive struct trees,
nullable immutable-class links, and a naturally indirect object/boolean union,
including nested validation failures. Full generated-consumer coverage is tracked
separately below; the prototype does not by itself establish generator correctness.

## 3. Proposed public model surface

### Objects

A theme schema should expose approximately this public surface. The schema body
and the typography initializer are omitted here for clarity.

```swift
public enum ThemeSchema {
  public struct Value: Sendable {
    public let name: String
    public let typography: Typography
    public let accentColor: String?

    public init(
      name: String,
      typography: Typography,
      accentColor: String? = nil
    ) {
      self.name = name
      self.typography = typography
      self.accentColor = accentColor
    }
  }

  public struct Typography: Sendable {
    public let fontFamily: String
    public let fontSize: Double
  }
}
```

The consumer continues to use the existing entry point:

```swift
let theme: ThemeSchema.Value =
  try ThemeSchema.schema.parseAndValidate(instance: json)

print(theme.typography.fontFamily)
```

Generation rules:

- Models live inside the existing namespace. Do not add top-level peers or
  per-model output files in the first version.
- Emit explicit initializers with appropriate access. Swift's synthesized
  memberwise initializer is not automatically public.
- Default only absent-capable fields to `nil`. A required nullable field still
  requires an initializer argument.
- Keep stored properties immutable and preserve schema field order.
- Match the enclosing macro namespace's effective access; CLI output stays public.
- Initializers construct values; they do not claim to enforce the JSON Schema.
  `parseAndValidate` remains the validation boundary.
- Initially synthesize only `Sendable`, not `Codable`, `Equatable`, or `Hashable`.

### Root output and containers

`Namespace.Value` always names the complete root output, but it need not always
be a struct.

| Schema shape | Named-mode representation |
| --- | --- |
| Nonnullable object with named fields | `struct Value` |
| Singleton object | `struct Value` with one field; no unwrapping |
| Object with no projected fields and no typed extras | Empty `struct Value` |
| Nullable object | `struct ObjectValue` and `typealias Value = ObjectValue?` |
| Primitive or nullable primitive | `typealias Value = String`, `String?`, etc. |
| Array of objects | Named item model and `typealias Value = [Item]` |
| Dictionary-only object | Named value model when needed; root remains a typed dictionary alias |
| Heterogeneous root union | `enum Value` |
| Boolean schema or genuinely untyped output | `typealias Value = JSONValue` |
| Heterogeneous `prefixItems` output | Preserve `[JSONValue]`; tuple-array modeling is separate work |

Root and recursive references must resolve to the same logical model, rather than
producing both a root `Value` and an equivalent recursively referenced copy.

### Additional properties and presence

For objects with named fields and typed additional properties, place the named
fields directly on the model and add an `additionalProperties` dictionary.
Resolve a collision with an actual JSON field of that name explicitly through
the generated-member naming rules; never overwrite or drop the real field.

Preserve the existing classification of additional keys:

- Declared and pattern-matched keys are not additional properties.
- A required-only name is not a declared property. It may appear both as a
  required projected field and in the additional-properties dictionary.
- Pattern properties remain validation-only in this enhancement.
- Boolean `additionalProperties` does not newly promise lossless capture of
  unknown fields.

Preserve all four field states:

| Presence/type | Stored Swift type | Initializer default |
| --- | --- | --- |
| Required, nonnullable | `T` | None |
| Optional, nonnullable | `T?` | `nil` |
| Required, nullable | `T?` | None |
| Optional, nullable | `T??` | Outer `nil` |

Constructor maps must not flatten `.some(nil)` into absence.

## 4. Internal architecture

The proposed pipeline is:

```text
Schema documents
  -> existing reference resolution and dynamic specialization
  -> shared semantic parsing plan + complete validation bindings
  -> model graph
  -> recursion/layout analysis
  -> deterministic symbol allocation
  -> SwiftSyntax declarations and parser expressions
  -> existing GeneratedSchema result
```

### Shared parsing plan

Extract the existing decisions about types, object fields, intersections,
nullable pairs, arrays, union branches, and reference use into an internal
`SchemaParsingPlan`.

Its nodes should describe operations and relationships rather than contain
already-rendered Swift strings. Keep separate references to the complete
validation definition and the typed parsing projection.

The tuple emitter and model emitter must consume the same semantic decisions.
Do not introduce a second implementation of JSON Schema intersection,
additional-property coverage, or union validity.

First prove that the extracted plan can reproduce existing tuple output without
changes. Avoid combining that refactor with a new naming algorithm in one step.

### Model graph

Add internal concepts along these lines:

| Concept | Required information |
| --- | --- |
| `ModelID` | Stable logical identity, independent of allocated Swift spelling |
| `ModelType` | Built-in, optional, array, dictionary, or model reference |
| `ModelDefinition` | Object, union, or useful named alias |
| Object field | Original JSON key, Swift label, presence, nullability, projected type |
| Union branch | Source location, payload type, original order, naming evidence |
| Provenance | Source and reference-use locations, canonical resource, dynamic specialization |
| Validation binding | The existing complete schema/projection association |
| Symbol allocation | Type names, case names, reserved symbols, private helper names |

An object reached through the same reference should share a model only when its
specialized output shape is compatible. Do not deduplicate unrelated objects
just because they currently have equal fields.

Likewise, never assign different validation behavior to a shared public model's
single static `schema`. Public models are values, not automatically `Schemable`
types. Private parsing adapters retain the binding between a model projection
and its actual validation context.

### Provenance preservation

Capture source names and reference-use origins before inlining or intersection
planning loses them. Preserve dynamic-scope identity and distinguish:

- A definition reused unchanged.
- The same definition with a use-site refinement that changes output shape.
- Separate dynamic specializations of the same raw definition.
- An object created by composing multiple source schemas.

Do not use current `ReferenceN` numbers, Swift `hashValue`, syntax descriptions,
or absolute checkout paths as public naming identities.

Use canonical resource identifiers where available. For file inputs without
canonical IDs, carry a stable logical document name separately from the
retrieval URI. An additive optional naming identity on `SchemaDocument`, or an
equivalent generation-context mapping, can provide this without altering
reference resolution. CLI/plugin callers supply portable logical file names;
inline generation uses a fixed logical document identity.

## 5. Deterministic type naming

Allocate names after discovering all reachable models in an output namespace.
Do not increment a global counter while walking parser expressions.

### Naming priority

1. An explicit, validated user override.
2. The fixed root role, normally `Value`.
3. A referenced `$defs` name or OpenAPI component name.
4. A meaningful property/use-site name.
5. A container role such as `ItemsItem`, `Entry`, or `ObjectValue`.
6. A contextual name with a stable disambiguating suffix.

Examples:

| Origin | Preferred name |
| --- | --- |
| `$defs/Typography` | `Typography` |
| `properties/address` containing an object | `Address` |
| `properties/events/items` containing an anonymous object | `EventsItem` |
| `properties/settings/additionalProperties` containing an object | `SettingsEntry` |
| `properties/result/oneOf` | `Result` |
| Object branch of an object/boolean root union | `ObjectValue` |

Do not add English singularization or acronym guessing in the first version.
`EventsItem` is predictable; users can override it to `Event`. Preserve already
valid names where possible and specify ASCII tokenization/casing rules in tests.

Use `title` and `description` as documentation by default, not type identities.
Changing prose should not unexpectedly rename the generated API.

### Collisions and reserved names

Reserve the root symbol, enclosing namespace, generated members, helper prefix,
and names that would shadow emitted built-in/runtime references.

For implicit collisions, progressively add meaningful context from the use site,
definition path, or logical document name. If context is still insufficient,
append a deterministic suffix derived from a portable logical identity. Specify
the digest algorithm and handle prefix collisions by extending the suffix.

An explicit override is a request for an exact spelling: invalid identifiers,
reserved names, or conflicting explicit names are errors, not silently renamed
overrides.

Emit module-qualified built-in/runtime references where appropriate, and verify
qualification and imports with a separate consumer. A generated model named
`String` or `JSONReference` must not accidentally change what another declaration
refers to.

Keep original JSON keys intact and continue using the existing field-label
mapping. Type/case naming is a separate algorithm; this feature should not
silently turn existing `some_key` fields into `someKey`.

### Stability contract

Test and document these guarantees:

- Identical inputs/options produce identical source.
- Batch order and dictionary iteration do not choose public names.
- Moving a checkout does not change generated names or embed developer paths.
- Adding an unrelated, noncolliding model does not rename existing named models.
- A description/title edit does not rename a model.
- Field and branch declaration order still follows the schema where meaningful.

There are limits: adding a competing name can require disambiguation, and moving
an anonymous schema to another pointer can change its identity. Exact long-lived
names should be pinned with overrides. Do not promise that arbitrary structural
schema edits are source-compatible.

## 6. Union names and cases

Name a union from its owning definition or property, not `UnionN`.

```swift
public enum Response: Sendable {
  case ready(Ready)
  case pending(Pending)
}
```

Choose case labels from:

1. Explicit case-name overrides.
2. A proven common required discriminator with distinct constant values.
3. Referenced definition or payload model names.
4. Primitive/container kinds: `string`, `integer`, `number`, `boolean`, `array`.
5. Neutral branch-local fallbacks when no meaningful distinction exists.

For discriminator-based naming, require conservative evidence: an object
domain, a required property, and distinct string `const` or singleton `enum`
values across the relevant branches. Reuse existing resolved constraints; do
not add a general satisfiability solver.

Discriminator information names cases only. It must not bypass the validator or
change `anyOf`'s first-valid-parse ordering or `oneOf`'s exactly-one-valid rule.

Retain common-output collapse when branches truly produce the same semantic
output, including the same model identity. Different definitions with distinct
nominal model identities are not equal merely because their fields match.
Reject an override for a case that will not be emitted rather than ignoring it.

Some schemas provide no useful names. A neutral `alternative1` is preferable to
inventing a business meaning. Such fallback cases are explicitly branch-order
dependent; they are not covered by the stronger semantic-name stability promise.

Keep nullable pairs as optionals. General unions containing null can use a
payload-free `.null` case rather than an awkward `Void` payload.

Primitive `enum` constraints do not automatically become new raw-value Swift
enums in the initial version described here. The subsequent typed-string-enum
enhancement is recorded in section 15.

## 7. Recursion and Swift layout

A JSON Schema reference cycle and an invalid Swift value-layout cycle are
different things.

```swift
struct Tree: Sendable {
  let children: [Tree]  // Valid: Array provides indirection.
}
```

By contrast, a struct containing `next: Node?` cannot recursively contain itself.
`Optional` does not provide storage indirection.

### Analysis

Build both a reference dependency graph and an inline-layout dependency graph.

In the layout graph, expand aliases and treat struct fields, tuples, optionals,
and ordinary enum payloads as inline. Arrays, dictionaries, classes, and indirect
enum payloads provide indirection.

Use strongly connected components to identify layout cycles. Mark existing
semantic unions `indirect` where this breaks cycles, then recompute the remaining
layout graph. Do not generate an extra public wrapper enum merely to hide an
unresolved object-layout problem.

### Explicit policies

Proposed `RecursiveObjectStrategy`:

| Policy | Behavior |
| --- | --- |
| `.valueTypes` | Default in model mode. Use structs and necessary indirect semantic unions; diagnose remaining object-layout cycles |
| `.immutableClasses` | Explicit permission to emit final immutable classes for object nodes in remaining cyclic layout components |

In class mode, convert the affected object nodes deterministically rather than
depending on traversal order or attempting an unstable minimum-cut heuristic.
Leave unrelated and collection-only recursive models as structs.

Classes have `let` properties, explicit initializers, and compiler-checked
`Sendable` conformance. Do not use `@unchecked Sendable`. Document that this mode
introduces reference semantics, even though parsed JSON does not imply preserved
object identity or shared aliases.

The default diagnostic should identify the actual cycle, for example:

```text
#/properties/next: Named model 'Node' has an inline value-layout cycle:
Node.next -> Node.
Use recursiveObjects: .immutableClasses to allow immutable reference models.
```

Rejecting a schema in strict value-type mode is an explicit representation
limitation, not a claim that its JSON Schema is invalid.

### Why the meta-schema can remain value-oriented

Its object-or-boolean shape already supplies a semantic enum that can provide
indirection. A partial proposed surface is:

```swift
public indirect enum Value: Sendable {
  case object(ObjectValue)
  case boolean(Bool)
}

public struct ObjectValue: Sendable {
  public let title: String?
  public let defs: [String: Value]?
  public let allOf: [Value]?
  public let not: Value?
}
```

The real output has more fields, but callers would access models directly rather
than repeatedly unwrapping `ReferenceN.value`.

### Runtime reference adapters

Retain lazy `JSONReference` parsing. Prototype private `Schemable` adapter types
that wrap a public model solely for the runtime protocol, then map the parsed
adapter back to that model before assigning fields.

These adapters do not solve public struct layout cycles; the analysis above
still must do that. They solve the runtime schema-binding problem without giving
every shared model an ambiguous public `schema`.

Preserve complete definition bundles, dynamic specialization, context isolation,
and explicit failures. Do not replace references with eager recursive factories.

## 8. Public options and all entry points

The following APIs are proposed, not currently available.

### Shared configuration types

Use a small dependency-free target, tentatively
`JSONSchemaCodegenConfiguration`, for:

- `SchemaOutputStyle`: `.tuples`, `.models`.
- `RecursiveObjectStrategy`.
- `SchemaNameOverrides`.
- `SchemaGenerationOptions`.

Both the generation core and the public macro library depend on/re-export these
types. Do not expose them by importing the SwiftSyntax-dependent core into the
application-facing library. No new public product is necessary initially.

### Core

```swift
let generator = SchemaGenerator(
  options: .init(
    output: .models,
    recursiveObjects: .valueTypes,
    names: .init(
      typeNames: ["#/$defs/Typography": "Typography"],
      caseNames: ["#/properties/result/oneOf/0": "ready"]
    )
  )
)
```

Preserve `SchemaGenerator()` and all existing generation methods. Apply options
consistently to inline source, batch generation, root-plus-registry generation,
and the internal OpenAPI root-selection path.

Keep `GeneratedSchema`'s existing expression/output/declarations properties.
Its named-mode `outputType` references `Value`; supporting declarations remain
inside the caller's namespace.

### Macro

```swift
@Schema(
  """
  {"type":"object","properties":{"name":{"type":"string"}}}
  """,
  output: .models,
  recursiveObjects: .valueTypes
)
enum PersonSchema {}
```

Support optional literal `typeNames` and `caseNames` dictionaries using the same
rules as core options. Keep the schema as the first unlabeled, non-interpolated
string literal.

Parse options from syntax; do not evaluate Swift expressions or read external
configuration files from a macro. Diagnose unknown/duplicate labels, invalid
cases, nonliteral dictionaries, and invalid override values at their arguments.

### CLI

```sh
swift run json-schema-codegen \
  --output-style models \
  --recursive-objects value-types \
  --output-directory Generated \
  Schemas/theme.schema.json
```

Add an explicit `--config` option for naming maps and reusable settings.
Precedence is built-in defaults, then the config file, then explicitly supplied
CLI flags. Track whether a flag was supplied so an implicit default cannot
overwrite configuration.

Keep existing filename rules, batch registration, deterministic output,
unchanged-file behavior, and validation of the entire batch before any write.

### Build-tool plugin

SwiftPM does not provide arbitrary per-use arguments to this build-tool plugin.
Use one explicit target-local `json-schema-codegen.json` configuration file.
Do not search parent directories or rely on environment variables for model
representation.

Example proposed configuration:

```json
{
  "version": 1,
  "output": "models",
  "recursiveObjects": "valueTypes",
  "typeNames": {
    "Schemas/common.schema.json#/$defs/Typography": "Typography"
  },
  "caseNames": {
    "Schemas/theme.schema.json#/properties/result/oneOf/0": "ready"
  }
}
```

The plugin passes the configuration to the CLI and includes it in build-command
`inputFiles`. Editing options must invalidate generated output. Keep the same
output filenames so mode changes do not leave an old second set of declarations.

Document how to exclude the config from compilation/resource discovery to avoid
SwiftPM unhandled-file warnings while still allowing the plugin to read it.
An absent config preserves current behavior. Malformed or unsupported-version
configurations fail explicitly.

### OpenAPI

Add matching options to `OpenAPISchemaGenerator` and forward them into the same
core path. Preserve component namespaces and source order. A referenced component
name is a naming hint, not a request to generate cross-namespace shared storage.

First-version reuse is within each generated namespace. Shared models across
separately emitted roots are deferred because they change output ownership,
visibility, and incremental-build behavior.

## 9. Override selectors and diagnostics

Overrides must be portable and resolvable before source emission.

- A fragment-only pointer is relative to a single entry-point document.
- Multi-root CLI/plugin configuration uses a document-qualified selector.
- Relative document paths in a config resolve against the config file's location.
- Core calls accept normalized document-qualified selectors or unambiguous
  single-root fragments; the core performs no file I/O.
- Resolve retrieval-URI and canonical-ID aliases to actual schema locations.
- Use JSON Pointer escaping, not string splitting that loses `/` or `~` in keys.
- An override identifies a type-bearing schema or a particular union branch.
  A source node that yields multiple incompatible specializations needs an
  unambiguous use-site selector or an explicit diagnostic listing candidates.
- If one shared model receives conflicting requested names from multiple sites,
  report the conflict; do not silently duplicate it or pick the first name.
- Reserve root `Value` in the first version; arbitrary root renaming is deferred.

Validate unknown keys, missing locations, non-emitted case targets, invalid Swift
names, reserved names, and collisions. Include both the configuration location
and the schema location when they differ.

Use the existing schema-pointer diagnostic style for schema problems and located
configuration diagnostics for option problems. No silent fallback to tuples,
generic `JSONValue`, or numbered names after an invalid explicit override.

## 10. Validation and emission invariants

This is an output-representation enhancement, not a validator rewrite.

The named emitter must:

- Preserve the complete validation definition and its reference identities.
- Keep original object/array evaluation annotations and `unevaluated*` scope.
- Preserve conditional, dependent-schema, and `allOf` behavior.
- Preserve branch order and full-schema union validity checks.
- Preserve all additional-property parsing errors and exact integer handling.
- Preserve caller format configuration and per-call validation-context isolation.
- Never infer a required object type just to obtain a convenient struct.

Where only constructor maps and public names change, assert that
`schema.schemaValue` is structurally equal between modes. Also compare actual
validation/parsing outcomes; schema-value equality is not a substitute for those.

Emit declarations, initializer calls, type references, and case maps with
structured SwiftSyntax. Do not reintroduce large interpolated declarations that
can exceed parser nesting limits. Use typed constructor closures where needed
to keep compiler inference bounded.

Pure generated schema-value helpers may be shared if useful. Do not share mutable
validation contexts or introduce new runtime caches as a compilation optimization.

## 11. Implementation sequence

Each phase has a concrete completion condition. These are implementation
milestones, not authorization to create a PR stack.

| Phase | Work | Completion condition |
| --- | --- | --- |
| 0. Baseline and feasibility | Freeze legacy fixtures; prototype named constructor maps, private reference adapters, indirect semantic unions, and immutable classes; verify imports/access on minimum Swift | Small generated consumers compile and run without a new runtime API |
| 1. Configuration and semantic plan | Add lightweight option types; extract shared parsing decisions and provenance; retain legacy emitter | Existing tuple-mode output and behavior remain unchanged |
| 2. Acyclic named objects | Add model graph, root `Value`, nested models, initializers, containers, typed extras, and nullable handling | Theme/plugin fixtures work with readable model access in core-generated consumers |
| 3. Names and reuse | Allocate type names, model identities, reference reuse, portable collision handling, and overrides | Naming stability/mutation tests and duplicate-definition fixtures pass |
| 4. Semantic unions | Add named enums/cases, conservative discriminator evidence, common-output rules, and null cases | Existing `anyOf`/`oneOf` fixtures have equivalent outcomes and usable enum APIs |
| 5. Recursive models | Analyze inline layout; add indirect semantic enums/private adapters; implement explicit class policy | Arrays/dictionaries, direct/mutual cycles, nullable lists, and dynamic trees behave as specified |
| 6. Surface integration | Wire macro options, CLI config/flags, plugin invalidation, and OpenAPI options | Equivalent options produce equivalent declarations through every entry point |
| 7. Conformance and usability | Run both representations, convert real examples, inspect the full generated meta-schema, measure builds, and document migration | Acceptance criteria below are met and remaining limits are explicit |

Do not document partially supported `.models` behavior as complete between
phases. During development, unsupported named shapes must fail explicitly rather
than quietly returning legacy tuple APIs.

### File organization

Core's public entry points remain at `Sources/JSONSchemaCodegenCore/`:
`SchemaGenerator.swift`, `SchemaDocument.swift`, `OpenAPISchemaGenerator.swift`,
and the `JSONSchemaCodegenCore.swift` configuration re-export.

Internal files are grouped in the same target:

- `Planning/` contains `SchemaReferenceGraph.swift`, `SchemaParsingPlan.swift`,
  `SchemaKeywords.swift`, and the extracted `SchemaEmitter.swift` coordinator.
- `Models/` contains `SchemaOutput.swift`, `SchemaModelGraph.swift`,
  `SchemaModelAllocation.swift`, and `SchemaModelLayout.swift`.
- `Naming/` contains `SchemaModelNames.swift`, `SchemaModelNameRequest.swift`,
  and `SchemaPropertyNames.swift`.
- `Syntax/` contains `SchemaSyntax.swift`, `RecursiveSchemaSyntax.swift`,
  `SchemaModelSyntax.swift`, and `SchemaStringEnumSyntax.swift`.

`SchemaEmitter` is internal so the public generator facade can construct and
invoke it; its planning helpers and mutable generation state remain private,
apart from read-only access to the consumed naming overrides. The folders are
organizational boundaries, not separate modules or a newly decoupled pipeline.
SwiftPM discovers their sources without an explicit source list.

Public option value types remain in `Sources/JSONSchemaCodegenConfiguration/`,
shared by the core and CLI configuration decoder. No additional graph,
inflection, or naming dependency is needed.

## 12. Test strategy and acceptance criteria

### Compatibility and core planning

Run the full existing package suite. Keep tuple-mode golden output, singleton
unwrapping, root-selection order, generated filenames, and existing parsing
behavior unchanged.

Add graph-level tests for stable IDs, provenance through references/intersections,
dynamic specialization, nominal reuse, and different definitions with equal
field shapes.

### Names

Cover reserved words, Unicode, punctuation, empty names, leading digits,
normalization collisions, imported-type shadowing, root/helper collisions, and
invalid/ambiguous overrides.

Use mutation tests: add an unrelated property/definition, reorder batch inputs,
change prose, move the checkout, and insert a noncolliding union elsewhere.
Verify that unrelated public names remain stable.

### Compiled consumer behavior

Compile actual generated consumers, not only snapshots. Include:

- Empty, singleton, and nested object models.
- Arrays and dictionary values containing models.
- Required/optional and nullable/nonnullable combinations, including `T??`.
- Named fields plus extras, required-only fields, pattern coverage, and empty keys.
- Equal-shaped but semantically distinct union payloads.
- Overlapping `anyOf`, exactly-one `oneOf`, and invalid discriminator payloads.
- Public/package macro namespaces and use from another module.
- Constructor access/defaults and compiler-checked `Sendable`.
- Recursive collections, direct optional links, mutually recursive objects,
  indirect unions, and strict value-type diagnostics.
- Nested/static/dynamic reference scopes and existing evaluation-isolation cases.

Verify that public field and case payload types do not expose private adapters.
Use the existing Testing/CustomDump infrastructure rather than introducing a new
test framework or duplicating transitive test dependencies.

### End-to-end parity

Extend the CLI/plugin/OpenAPI smoke scripts to exercise both output modes.
Check plugin regeneration after config changes and unchanged-file timestamps
when inputs/options are unchanged. Fail an invalid batch before writing files.

Run the official meta-schema example in model mode. Its positive, negative, and
self-validation checks must still pass. Add typed-access checks demonstrating
that nested schemas are usable without `ReferenceN.value` traversal.

Extend the generated-code conformance harness to select or compare both modes.
Require identical generation support and instance outcomes, except explicitly
documented strict value-layout refusals; rerun those under the approved class
policy rather than treating them as validator failures or silently skipping them.

The current baseline contains two explicitly unsupported custom-dialect groups.
Continue reporting them separately; this work must not make them disappear from
the summary or count them as passed.

### Size and compilation budget

Before implementation, record generated source size, declaration counts,
generation duration, and clean/incremental consumer build times for a small
configuration, the theme example, and the official meta-schema.

Compare modes on the same toolchain and hardware using isolated scratch builds
and repeated measurements. Proposed investigation thresholds are a median
consumer-build increase above 25% or parsing-time increase above 20% relative to
the corresponding legacy fixture. Establish absolute budgets from the baseline;
these are proposed review thresholds, not measured results or promises.

Do not turn noisy shared-runner timing into a flaky correctness test. Structural
checks for duplicate model emission and deterministic output can run in CI.

### Definition of done

The enhancement is ready when:

- Default callers retain their current API and generated output.
- Named mode provides a coherent `Value` surface across all supported root shapes.
- The real configuration examples are visibly simpler to consume.
- Model/type/case names follow documented deterministic rules.
- Recursion works without public adapter wrappers, or produces the explicit
  selected representation-policy diagnostic.
- Validation parity holds across generated consumers and official fixtures.
- Macro, core, CLI, plugin, and OpenAPI paths are all wired.
- Runtime version requirements and remaining limitations are accurate.

## 13. Non-goals and approval checkpoints

Defer automatic `Codable` generation, JSON encoding, model mutation APIs,
automatic object/union `Equatable`/`Hashable`, arbitrary custom
dialects, heterogeneous prefix-array models, shared types across output
namespaces, and user-written partial model bodies.

Recommended decisions to approve before implementation:

| Decision | Recommendation |
| --- | --- |
| Default representation | Keep tuples; opt into models |
| Root naming | Fixed `Namespace.Value`, using aliases when necessary |
| Object storage | Immutable structs; explicit immutable-class permission for remaining layout cycles |
| Public model initialization | Explicit, nonvalidating initializers; only absent-capable fields get defaults |
| Naming configuration | Explicit maps outside schema annotations; prose does not choose names |
| Plugin configuration | One versioned target-local file, tracked as a build input |
| Union representation | Preserve validity/order/common-output semantics; improve emitted names |
| Reuse boundary | Within one generated namespace, with specialization-aware identities |

The highest-risk work is extracting the semantic plan without changing existing
behavior, preserving identity through dynamic/composed schemas, and binding
recursive parsers without leaking adapters. Validate those early. More attractive
names are valuable, but they are not a substitute for those correctness checks.

## 14. Implementation record

The core, macro, CLI, target-local plugin configuration, and OpenAPI adapter now
share the opt-in named-model options. Tuple mode remains the default. The
design-token and official meta-schema examples explicitly select named mode.

The implementation includes model identities and provenance, contextual/hash
naming, explicit type/case overrides, direct constructor mappings, semantic
unions, private recursive adapters, inline-layout analysis, and the opt-in
immutable-class policy. Compiled regressions also cover percent-escaped
selectors, outer-type-refined union branches, a field named `self`, internal
parameter collisions, explicit lowercase type names, and reserved namespace
members. Named constructors consume raw property outputs directly rather than
adding a model mapping after the legacy field-label mapping.

### Local verification

The checks below were rerun on Swift 6.4 / macOS using published
`swift-json-schema` 0.14.0, after removing all six editable runtime overrides.
The release also introduced exact number tokens; generation now preserves
numbers outside Swift numeric precision/range and rejects fractional count
bounds without rounding. Focused generation and compiled macro regressions
cover this compatibility update.
The package's Swift 6.1/platform minimums were not changed; this is not a claim
that the minimum compiler or Linux matrix was executed locally.

| Check | Result |
| --- | --- |
| Full package suite | 42 XCTest macro tests, 91 runtime tests, and 148 core tests passed |
| Separate generated library and consumer | 24 named/tuple pairs passed public type/initializer, typed-access, `Sendable`, relocation, validation parity, and negative-compilation checks |
| CLI and plugin | Existing CLI behavior plus named design-token consumer passed |
| Named entry points | Configuration precedence, invalid configuration, plugin regeneration, batch order, recursion policy, and escaped selectors passed |
| OpenAPI | Both representations passed the real composed Style API consumer; original component selectors also passed explicit-name coverage |
| Official meta-schema | Named recursive access and initialization passed; 15 valid cases, 53 invalid cases, and all eight official documents checked |
| Official 2020-12 suite | Both modes generated 382/384 groups; 1,296 unique instances, 2,592 mode-specific checks, zero schema-value or instance-result mismatches |
| Formatting | Strict formatting and diff whitespace checks passed for the release update; the initial implementation also passed strict formatting on all 55 changed Swift files |

The two official `vocabulary.json` custom-dialect groups remain explicit
generation failures. The full conformance command therefore exits nonzero;
those groups are not counted as supported or silently filtered.

CI includes the named-consumer, entry-point, and meta-schema scripts alongside
the existing package/CLI/OpenAPI checks. The dependency requirement has since
advanced to the published runtime 0.14.0; editable checkout state is not part of
the PR. No codegen release was created.

### Remaining representation boundary

Pure recursive container aliases have no finite Swift nominal model boundary.
For example, `{"type":"array","items":{"$ref":"#"}}` cannot become
`typealias Value = [Value]`. Named mode reports a located representation error
for these array/dictionary-only cycles under either recursion policy. It does
not leak adapters, erase the output to `JSONValue`, or introduce a new public
container-wrapper API. Tuple mode remains available.

### Measured generation and consumer costs

The following are local medians of three runs on the same Swift 6.4 toolchain.
Consumer-only clean builds remove the consumer's object/module outputs while
retaining dependency build outputs. Incremental builds change no inputs. Parsing
reuses a generated component and a decoded instance; it includes validation.
Type-declaration counts include namespaces, aliases, and private adapters.

| Schema set | Output | Source bytes | Type declarations | CLI generation (s) | Clean consumer build (s) | No-change build (s) | Parse and validate (ms/instance) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small configuration | Tuples | 1,069 | 1 | 0.015 | 1.423 | 1.033 | 0.176 |
| Small configuration | Models | 1,899 | 3 | 0.020 | 1.399 | 1.043 | 0.177 |
| Design-token batch | Tuples | 18,289 | 4 | 0.117 | 1.558 | 1.052 | 3.146 |
| Design-token batch | Models | 25,025 | 19 | 0.173 | 1.494 | 1.042 | 3.187 |
| Eight meta-schema documents | Tuples | 186,523 | 24 | 1.439 | 5.458 | 1.108 | 337.575 |
| Eight meta-schema documents | Models | 206,740 | 32 | 1.606 | 5.229 | 1.042 | 337.890 |

The initial named emitter exceeded the investigation threshold: its meta-schema
consumer build measured 8.080 seconds against 5.890 seconds for tuples. Removing
redundant intermediate tuple mappings eliminated that observed regression while
preserving the compatibility and consumer checks. The final comparison is within
both proposed investigation thresholds for all three schema sets. These small
samples are development observations, not general performance guarantees or
timing-based CI assertions.

## 15. Typed string-enum enhancement

Named output now extends the existing graph with a finite `stringEnum` shape,
not a second model system. `SchemaParsingPlan.StringEnum` records a positive
enum bound, the original values/indices, and provenance. The intersection planner
can carry that bound into a string projection; the complete validation binding
is unchanged. `SchemaModelAllocation` uses the existing type/case allocator and
overrides, and `SchemaStringEnumSyntax` emits declarations and fallible upstream
`compactMap` conversion. String-enum nodes have no inline layout dependencies.

### Representation and exactness

Each public payload-free enum exposes `init?(rawValue: String)` and
`rawValue: String`, with `RawRepresentable`, `Sendable`, and explicit exact
`Equatable`/`Hashable` behavior. A synthesized `enum E: String` is unsuitable:
Swift raw-value matching merges canonically equivalent strings, unlike JSON's
Unicode-scalar equality. Even a manually implemented `RawRepresentable` enum
inherits raw-value-based equality/hash defaults unless overridden. The emitter
therefore compares scalar sequences and hashes the same scalar sequence.
Distinct JSON strings survive parsing, case identity, sets, and raw conversion.

Case IDs contain UTF-8 hex value bytes, independent of enum order and Swift's
canonical `String` equality. Exact duplicates share a case, while all original
enum indices remain selectors and the validation literal is left untouched.
Entry provenance is captured before reference specialization changes the model
identity. Intersections and enum-valued reference siblings contribute selectors
by exact value rather than by projected-array position, so reordered/subset
refinements cannot rename the wrong case. Entries outside the chosen bound have
no case, and conflicting names for matching entries are diagnosed.
ASCII case normalization, contextual type naming, collision digests, namespace
boundaries, and explicit-name diagnostics reuse the existing contracts.
`rawValue`, `RawValue`, `hash`, and `hashValue` are reserved case names.

### Bounded applicability

The source enum must have at least one string and no non-string entries except
null. String and nullable-string parsing domains are eligible; when there is no
type, a pure enum supplies that domain. Nullable pairs and optional fields keep
the existing `T?`/`T??` semantics. Empty/null-only enums, other mixed-type enums,
unconstrained strings, and standalone `const` keep their previous output.
Numeric/boolean enums and automatic `Codable` remain out of scope.

Only positive conjunctive enum evidence supplies a finite bound. Intersections
retain the first such bound, possibly a superset of the values allowed by the
full schema, rather than adding a satisfiability solver. A second enum, `const`,
pattern, `not`, or conditional still validates normally. `anyOf` and `oneOf`
retain their selection/validity rules and independently modeled payloads;
an unconstrained alternative never gets narrowed to a neighbor's enum.

References reuse nominal identity as before; adding an enum-valued sibling is
an output-shape specialization, including when the base is an unconstrained
string. Validation-only refinements can share the base enum. Different source
definitions remain distinct regardless of equal values. Enum type overrides
target the schema location and case overrides target original `/enum/<index>`
locations, including enum-bearing `allOf` conjuncts.

No public configuration option or runtime dependency change is needed: this is
part of `.models` everywhere, on published `swift-json-schema` 0.14.0 or later.
Tuple generation, exact-number handling, and the immutable-class recursion
policy are unchanged.

### Verification

On Swift 6.4 / macOS with the published 0.14.0 runtime, the package suite passes
43 XCTest macro tests, 161 core tests, and 99 runtime tests. Focused coverage
includes scalar-exact conversion/equality/hashing, duplicate and escaped values,
null presence, naming stability, nominal reuse, reference specialization,
composition validation parity, and a recursively refined enum union.

The pinned official suite at `f6fd52a0a95472e079cbfc6ef7f089702b80e045`
still generates 382/384 groups: 1,296 unique instances / 2,592 mode checks, with
zero schema-value or runtime mismatches. The two custom-vocabulary dialect
groups remain explicit unsupported-generation errors and the full command
still exits nonzero. The 33 separate named/tuple public-consumer pairs, named
CLI/plugin entry-point checks, existing CLI/plugin smoke suite, OpenAPI smoke
suite, and official meta-schema smoke checks also pass. The design-token
example now uses typed mode cases and bridges namespace-local enum types through
their exact raw-string initializer.
This does not claim local execution on Linux or the minimum Swift 6.1 compiler;
the package's minimum tools version and platforms are unchanged.

The local consumer/example manifests give the codegen dependency an explicit
package name, so these checks can run in an isolated worktree whose directory
name differs from `swift-json-schema-codegen`, without touching another checkout.
