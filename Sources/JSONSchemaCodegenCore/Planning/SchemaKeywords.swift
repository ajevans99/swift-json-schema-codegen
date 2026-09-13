enum SchemaKeywords {
  static let maps = ["$defs", "properties", "patternProperties", "dependentSchemas"]
  static let arrays = ["allOf", "anyOf", "oneOf", "prefixItems"]
  static let singles = [
    "items", "not", "additionalProperties", "propertyNames", "contains",
    "if", "then", "else", "unevaluatedProperties", "unevaluatedItems", "contentSchema",
  ]
}
