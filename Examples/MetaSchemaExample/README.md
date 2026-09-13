# JSON Schema 2020-12 meta-schema example

This SwiftPM executable uses `JSONSchemaCodegenPlugin` and the local package at
`../..` to generate Swift from the **official, unmodified JSON Schema 2020-12
meta-schema and its seven vocabulary meta-schemas**. `meta.schema.json` produces
the `MetaSchema` namespace.

Generated recursive schemas use `JSONComponents.Projection`, available in the
required `swift-json-schema` 0.14.0 release. SwiftPM resolves that dependency
through the root package; no local runtime checkout is needed. The optional
override described below is only for upstream runtime development.

From the repository root:

```sh
swift run --package-path Examples/MetaSchemaExample MetaSchemaExample
```

For fixture integrity checks plus the plugin build and runtime smoke test:

```sh
bash Tests/MetaSchema/smoke.sh
```

These commands require Swift 6.1 or newer; the fixture checker also requires
Python 3. The first SwiftPM build can require network access to fetch package
dependencies. **Schema generation and validation need no network access**:
all schema documents are checked in, and their canonical `$id` values allow
references such as `meta/core` to resolve against the local resource set. After
building, run the existing executable without building or resolving dependencies:

```sh
swift run --skip-build --package-path Examples/MetaSchemaExample MetaSchemaExample
```

The target-local `json-schema-codegen.json` opts into named models. The consumer
uses `MetaSchema.Value`, semantic `.object`/`.boolean` cases, and recursive
dictionary values directly, without `ReferenceN.value` adapters:

```swift
let value: MetaSchema.Value = try MetaSchema.schema.parseAndValidate(
  instance: #"{"title":"Example","properties":{"enabled":true}}"#
)
if case .object(let schema) = value {
  print(schema.title)
  if case .some(.boolean(let enabled)) = schema.properties?["enabled"] {
    print(enabled)
  }
}

let constructed: MetaSchema.Value = .object(.init(title: "Constructed"))
```

The generated objects remain structs: the schema's natural object/boolean enum
provides recursion indirection. Initializers construct immutable values; they do
not validate JSON Schema constraints. The executable also:

- Accepts empty, object, and boolean schemas, recursive definitions, type unions,
  applicators, annotations, and legacy compatibility keywords.
- Rejects non-schema JSON values, invalid `type` values, malformed or duplicate
  `required` entries, invalid numeric bounds, and recursively invalid schemas
  inside `$defs`, properties, applicators, content, and unevaluated keywords.
- Requires invalid inputs to fail **schema validation**, not merely JSON decoding
  or parsing of the generated output.
- Validates the root meta-schema and all seven vocabulary documents against
  `MetaSchema` itself, using the bundled copies.

This validates **schema documents**, not instances described by those documents.
For example, `{"required":["name"]}` is a valid schema; a schema document need not
itself contain a `name` property. Format annotations are not promoted to format
assertions by this example.

## Local upstream runtime

The smoke script configures an editable `swift-json-schema` dependency for this
example when `JSON_SCHEMA_RUNTIME_PATH` is set. Otherwise, it automatically
reuses the root workspace's `Packages/swift-json-schema` checkout if present.
It does not modify the root workspace's dependencies or any upstream files.

To configure the dependency **without building or running the example**:

```sh
JSON_SCHEMA_RUNTIME_PATH=/path/to/swift-json-schema \
  bash Tests/MetaSchema/configure-runtime.sh
```

If the root workspace already has the desired editable runtime:

```sh
bash Tests/MetaSchema/configure-runtime.sh
```

To configure and run the full smoke test once the generator and runtime changes
are ready:

```sh
JSON_SCHEMA_RUNTIME_PATH=/path/to/swift-json-schema \
  bash Tests/MetaSchema/smoke.sh
```

Configuration is idempotent for the same checkout. A conflicting or broken
example-level edit fails with instructions rather than silently replacing it.
The helper first attempts `swift package edit`; it explicitly resolves
dependencies only if SwiftPM reports that the dependency is missing. SwiftPM
may also resolve dependencies itself during the first edit.
Without either override source, the helper leaves the example's existing
dependency configuration unchanged. A root-level edit alone does not propagate
automatically to independent SwiftPM example workspaces.

Editable links and build state are local, ignored SwiftPM artifacts; no personal
checkout path is stored in this example's manifest or scripts. To leave edit mode
after a compatible runtime is available:

```sh
swift package --package-path Examples/MetaSchemaExample unedit swift-json-schema
```

Also unset `JSON_SCHEMA_RUNTIME_PATH` and remove the root workspace's edit when
appropriate before using the smoke script without a local override.

## Offline fixture integrity

```sh
python3 Tests/MetaSchema/check-fixtures.py
```

This build-free check verifies the exact eight-document set, canonical IDs,
SHA-256 checksums, JSON Pointers, anchors, and availability of every `$schema`,
`$ref`, and `$dynamicRef` target locally. It does not claim to verify dynamic
scope or validator behavior; those are exercised by the Swift consumer.

## Provenance and license

Downloaded from the following official URLs on **2026-09-11**. Only local
filenames differ; document bytes, canonical IDs, and references are preserved.
The integrity manifest is `Sources/MetaSchemaExample/Schemas/SHA256SUMS`.

| Local path within `Schemas` | Official source |
| --- | --- |
| `meta.schema.json` | <https://json-schema.org/draft/2020-12/schema> |
| `meta/core.schema.json` | <https://json-schema.org/draft/2020-12/meta/core> |
| `meta/applicator.schema.json` | <https://json-schema.org/draft/2020-12/meta/applicator> |
| `meta/unevaluated.schema.json` | <https://json-schema.org/draft/2020-12/meta/unevaluated> |
| `meta/validation.schema.json` | <https://json-schema.org/draft/2020-12/meta/validation> |
| `meta/meta-data.schema.json` | <https://json-schema.org/draft/2020-12/meta/meta-data> |
| `meta/format-annotation.schema.json` | <https://json-schema.org/draft/2020-12/meta/format-annotation> |
| `meta/content.schema.json` | <https://json-schema.org/draft/2020-12/meta/content> |

These third-party schema documents are **not relicensed under this repository's
MIT license**. The JSON Schema Specification Authors distribute their source
under a choice of BSD 3-Clause or Academic Free License 3.0, as documented in the
[upstream README](https://github.com/json-schema-org/json-schema-spec/blob/4f56a9900674b27804f0ec32e3b7fdfa4efad695/README.md#license).
This example uses the **BSD 3-Clause option**. The complete upstream license,
including its copyright notice and disclaimer, is preserved as
[`LICENSE-JSON-SCHEMA.txt`](Sources/MetaSchemaExample/Schemas/LICENSE-JSON-SCHEMA.txt)
and copied into the executable's resource bundle with the schemas.
The license was obtained from
[upstream revision `4f56a9900674b27804f0ec32e3b7fdfa4efad695`](https://github.com/json-schema-org/json-schema-spec/blob/4f56a9900674b27804f0ec32e3b7fdfa4efad695/LICENSE).

The fixture source of truth is the published URLs above, not a substitution of
files from a specification repository tag. To update fixtures, download each URL
to its corresponding path, review document and license changes, update the
date and SHA-256 manifest, then run both checks above.
