# Release notes

## Unreleased

### Breaking changes

- Removed `OpenAPISchemaGenerator` and `GeneratedOpenAPISchema` from
  `JSONSchemaCodegenCore`, along with the OpenAPI components example.
  Use [Swift OpenAPI Schema Codegen](https://github.com/ajevans99/swift-openapi-schema-codegen)
  for OpenAPI generation. The generic JSON Schema generation APIs remain available.
