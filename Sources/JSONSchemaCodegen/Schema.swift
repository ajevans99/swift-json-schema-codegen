@_exported import JSONSchema
@_exported import JSONSchemaBuilder

/// Adds a typed `static var schema` to an empty namespace enum.
///
/// The schema is checked and lowered to builder expressions at compile time.
/// Objects with multiple properties produce labeled tuples. A single-property
/// object produces that property's value, and an empty object produces `Void`.
/// Optional properties remain optional independently of nullable value types.
/// Composition can add nested public `Sendable` enums named `Union1`, `Union2`,
/// and so on, with `option1`, `option2`, ... cases in schema branch order.
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
/// expose `schema` at the same access level. Interpolation, runtime strings, and
/// unsupported schema keywords are errors. Local `$defs`, `$ref`, `$id`, and
/// `$anchor` references resolve within the literal. References to other files
/// belong in the CLI or build plugin's explicit document batch.
@attached(member, names: named(schema), arbitrary)
public macro Schema(_ json: String) =
  #externalMacro(module: "JSONSchemaCodegenMacros", type: "SchemaMacro")
