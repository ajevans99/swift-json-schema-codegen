# OpenAPI components example

This standalone Swift 6.1 package reads the authored [Style API document](Fixtures/style-api.openapi.json)
with `OpenAPISchemaGenerator` and emits JSONSchemaBuilder declarations. It does not
use a macro or build-tool plugin to generate the components.

## Run from VS Code

Open the repository folder, then choose **Tasks: Run Task** from the Command
Palette:

- **Examples: Generate OpenAPI Swift** saves the generated code to
  `.build/openapi-preview/StyleAPI.generated.swift`. Open that path with Quick
  Open (`Cmd+P` on macOS or `Ctrl+P` on Windows/Linux).
- **Examples: Run OpenAPI integration** compiles the generated code and runs the
  payload checks.
- **Examples: Run build-plugin example** runs the separate SwiftPM plugin example.

Edit [Fixtures/style-api.openapi.json](Fixtures/style-api.openapi.json) and rerun
the generation task to see how a schema change affects the Swift output. The
preview file stays on disk and is ignored by Git.

## Run from the terminal

Save generated Swift to the same preview file:

```sh
bash Examples/OpenAPIExample/generate.sh
```

From the repository root, generate Swift on stdout:

```sh
swift run --package-path Examples/OpenAPIExample openapi-generate \
  Examples/OpenAPIExample/Fixtures/style-api.openapi.json

# Opt into Value models and semantic ready/pending response cases.
swift run --package-path Examples/OpenAPIExample openapi-generate \
  Examples/OpenAPIExample/Fixtures/style-api.openapi.json --output-style models
```

Build and run the complete generated-source integration check:

```sh
bash Tests/OpenAPI/smoke.sh
```

The smoke script stages a separate consumer package under the repository's
`.build` directory, writes generated Swift into it, then compiles and executes
[`Consumer/main.swift`](Consumer/main.swift) in both tuple and named modes.
Named mode also checks `ThemeSchema.Value` and `.ready`/`.pending` payloads;
tuple mode retains the existing `.option1`/`.option2` API. Staged sources are
removed on exit; the build caches remain in `.build/openapi-consumer` and
`.build/openapi-consumer-models`.

The fixture and consumer exercise:

- Forward and shared `#/components/schemas/...` references.
- An `allOf` theme combining required identity, palette, and typography fields.
  Its base object is deliberately open: `allOf` cannot extend an object that
  rejects the extension's fields using `additionalProperties: false`.
- An `anyOf` font family with two pattern-constrained `String` alternatives.
- A `oneOf` response with different ready/pending payload types. Const tags,
  rather than merely successful object parsing, determine the generated enum case.
- Nested array unions with supporting declarations in independent namespaces.
- Invalid payloads rejected for missing fields, unknown tags, and violated constraints.

The adapter handles only OpenAPI **3.1.x JSON** `components.schemas`. It is not a
full OpenAPI validator or HTTP client generator. It recognizes the OpenAPI 3.1
base dialect and JSON Schema 2020-12, but rejects custom dialects and OpenAPI
3.0. OpenAPI-only `discriminator` and legacy `nullable` are retained as annotations,
not interpreted as validation or naming instructions. Semantic cases come from
required JSON Schema discriminator fields with distinct constant values.
The adapter performs no network reads and does not generate operation objects
or modify the input files. Explicit OpenAPI base `$schema` declarations are normalized
to JSON Schema 2020-12 at schema-bearing locations; annotations and `$id` scopes
are preserved. The small example emitter requires ASCII identifier
component names; the core adapter preserves arbitrary names and escaped pointers.
