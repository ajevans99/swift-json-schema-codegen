# `#schema` Macro Plan

> Implementation update: Swift requires expression-macro result types before
> expansion, so the package uses `@Schema(jsonLiteral) enum ThemeSchema {}` and
> generates `ThemeSchema.schema` instead. This preserves automatic output-type
> generation without asking callers to repeat the tuple type. The original
> expression-macro proposal below is retained as design history.
>
> Object outputs remain labeled tuples for two or more properties. Swift has
> no one-element labeled tuples, so singleton objects return the property's
> value directly; objects with no declared properties return `Void`.

## Goal

Add a freestanding expression macro that turns an inline JSON Schema literal into a strongly typed `JSONSchemaComponent`. Object schemas parse into labeled tuples, while the existing builder components provide validation and parsing behavior.

```swift
let themeSchema = #schema("""
{
  "type": "object",
  "properties": {
    "primaryColor": {
      "type": "string",
      "pattern": "^#[0-9a-fA-F]{6}$"
    },
    "iconUrl": { "type": "string" }
  },
  "required": ["primaryColor"]
}
""")

let theme = try themeSchema.parseAndValidate(instance: input)
theme.primaryColor  // String
theme.iconUrl       // String?
```

## Compilation Model

```text
#schema literal
    -> expression macro parses and checks the schema
    -> transient macro planning model
    -> generated JSONSchemaBuilder expression (lowered IR)
    -> Swift result-builder expansion and type checking
    -> JSONSchemaComponent with a labeled-tuple Output
```

The macro is the front end that **produces** the result-builder IR. The result builders then assemble the concrete component type and its inferred output.

## MVP

- Require a compile-time string literal containing JSON.
- Support boolean schemas, primitives, objects, nested objects, and homogeneous arrays.
- Derive requiredness from the parent object's `required` array, independently of nullability.
- Emit labeled tuples for objects and preserve optional properties as optional tuple elements.
- Lower supported constraints to existing builder modifiers, including string, number, array, object, and annotation modifiers.
- Emit precise compile-time diagnostics with schema locations.
- Reject unsupported or lossy constructs rather than silently weakening the schema.

## Package Shape

- A shared codegen core for parsing, reference resolution, planning, diagnostics, and builder-source emission.
- A macro implementation target that applies the core to inline literals.
- A CLI executable that applies the same core to schema files.
- A SwiftPM build-tool plugin that invokes the CLI over all `*.schema.json` inputs in a target and emits derived Swift source.
- A public macro declaration exposed alongside `JSONSchemaBuilder`.
- Expansion tests plus integration tests proving inferred tuple types, parsing, and constraint validation.

The plugin should process all schema inputs together rather than invoke codegen independently per file. This provides one `$id`/`$defs`/`$ref` graph and supports relative or shared references across documents.

## Follow-On Work

Local `$defs`/`$ref` graph resolution and offline cross-document references are
implemented in the shared core, CLI, and build plugin. This includes nested `$id`
resources, static anchors, original-source diagnostics, and cycle detection.
Reference siblings preserve intersection semantics and share `allOf`'s
output-shaping rules. Composition now supports merged object projections,
same-output unions and generated enum unions using the existing builder APIs.

1. Decide on nominal object output types before supporting recursive schemas.
2. Extend the bounded OpenAPI 3.1 components adapter to more document surfaces.
