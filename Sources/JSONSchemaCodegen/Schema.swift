@_exported import JSONSchema
@_exported import JSONSchemaBuilder

/// Adds a typed `static var schema` to an empty namespace enum.
///
/// The schema is checked and lowered to builder expressions at compile time.
/// Objects with multiple properties produce labeled tuples. A single-property
/// object produces that property's value, and an empty object produces `Void`.
/// Optional properties remain optional independently of nullable value types.
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
/// unsupported schema keywords are errors.
@attached(member, names: named(schema))
public macro Schema(_ json: String) =
  #externalMacro(module: "JSONSchemaCodegenMacros", type: "SchemaMacro")
