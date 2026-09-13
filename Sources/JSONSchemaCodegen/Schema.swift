@_exported import JSONSchema
@_exported import JSONSchemaBuilder
@_exported import JSONSchemaCodegenConfiguration

/// Adds a typed `static var schema` to an empty namespace enum.
///
/// The schema is checked and lowered to builder expressions at compile time.
/// By default, objects with multiple properties produce labeled tuples. A single-property
/// object produces that property's value, and an empty object produces `Void`.
/// Optional properties remain optional independently of nullable value types.
/// Composition can add nested public `Sendable` enums named `Union1`, `Union2`,
/// and so on, with `option1`, `option2`, ... cases in schema branch order.
/// Recursive targets add indirect `ReferenceN` enums with a `value` payload.
/// Arbitrary JSON property names receive collision-safe Swift labels while
/// retaining their original JSON keys.
///
/// ```swift
/// @Schema("""
///   {"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name"]}
///   """)
/// enum PersonSchema {}
///
/// let person = try PersonSchema.schema.parseAndValidate(instance: #"{"name":"Blob"}"#)
/// // person.name is String; person.age is Int?.
/// ```
///
/// The enum must be empty and outside generic contexts. Public and package enums
/// expose `schema` at the same access level. Interpolation, runtime strings,
/// malformed schemas, and unsupported dialects are errors. Unknown extension
/// keywords remain annotations. Local `$defs`, `$ref`, `$dynamicRef`, `$id`,
/// `$anchor`, and `$dynamicAnchor` resolve within the literal. References to
/// other files belong in the CLI or build plugin's explicit document batch.
/// Complete-schema validation is separate from the typed parsing projection.
///
/// Use `output: .models` to generate named models and a `Value` root type instead
/// of tuples. `recursiveObjects: .immutableClasses` explicitly permits immutable
/// reference models where a recursive object cannot have value-type storage.
/// Naming dictionaries map literal schema selectors to exact Swift identifiers;
/// all options must be literal syntax, not runtime expressions.
@attached(member, names: named(schema), arbitrary)
public macro Schema(
  _ json: String,
  output: SchemaOutputStyle = .tuples,
  recursiveObjects: RecursiveObjectStrategy = .valueTypes,
  typeNames: [String: String] = [:],
  caseNames: [String: String] = [:]
) =
  #externalMacro(module: "JSONSchemaCodegenMacros", type: "SchemaMacro")
