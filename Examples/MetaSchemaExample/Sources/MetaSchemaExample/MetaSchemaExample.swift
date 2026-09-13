import Foundation
import JSONSchemaCodegen

@main
enum MetaSchemaExample {
  static func main() throws {
    try verifyNamedOutput()

    for (label, instance) in validSchemas {
      do {
        _ = try MetaSchema.schema.parseAndValidate(instance: instance)
      } catch {
        throw ExampleFailure("\(label) should be a valid schema: \(error)")
      }
    }

    for (label, instance) in invalidSchemas {
      try expectValidationFailure(label, instance: instance)
    }

    for document in officialDocuments {
      _ = try MetaSchema.schema.parseAndValidate(instance: schemaDocument(document))
    }

    print(
      "Meta-schema example passed: \(validSchemas.count) valid schemas, "
        + "\(invalidSchemas.count) invalid schemas, "
        + "\(officialDocuments.count) official documents self-validated offline."
    )
  }

  private static func verifyNamedOutput() throws {
    let parsed: MetaSchema.Value = try MetaSchema.schema.parseAndValidate(
      instance: #"""
        {
          "title": "Named schema",
          "type": "object",
          "properties": {
            "enabled": true,
            "child": {"title": "Child", "type": "string"}
          },
          "required": ["child"]
        }
        """#)
    guard case .object(let schema) = parsed,
      schema.title == "Named schema",
      schema.required == ["child"],
      case .some(.boolean(true)) = schema.properties?["enabled"],
      case .some(.object(let child)) = schema.properties?["child"],
      child.title == "Child"
    else {
      throw ExampleFailure("Named meta-schema models did not preserve recursive typed fields.")
    }

    let constructed: MetaSchema.Value = .object(.init(title: "Constructed"))
    guard case .object(let schema) = constructed, schema.title == "Constructed" else {
      throw ExampleFailure("Named meta-schema model initializer did not preserve its arguments.")
    }
  }

  private static let officialDocuments = [
    "meta.schema.json",
    "meta/core.schema.json",
    "meta/applicator.schema.json",
    "meta/unevaluated.schema.json",
    "meta/validation.schema.json",
    "meta/meta-data.schema.json",
    "meta/format-annotation.schema.json",
    "meta/content.schema.json",
  ]

  private static let validSchemas: [(String, String)] = [
    ("empty schema", "{}"),
    ("true schema", "true"),
    ("false schema", "false"),
    ("string schema", #"{"type":"string","minLength":1}"#),
    ("type union", #"{"type":["object","boolean"]}"#),
    ("empty required list", #"{"required":[]}"#),
    (
      "nested object",
      #"""
      {
        "type": "object",
        "properties": {
          "name": {"type": "string"},
          "children": {
            "type": "array",
            "items": {"$ref": "#"}
          },
          "enabled": true,
          "forbidden": false
        },
        "required": ["name"],
        "additionalProperties": false
      }
      """#
    ),
    (
      "recursive definitions",
      #"""
      {
        "$defs": {
          "node": {
            "type": "object",
            "properties": {
              "value": {"type": ["string", "null"]},
              "next": {"$ref": "#/$defs/node"}
            }
          }
        },
        "$ref": "#/$defs/node"
      }
      """#
    ),
    (
      "schema-valued applicators",
      #"""
      {
        "allOf": [true, {"type": "object"}],
        "anyOf": [false, {"required": ["name"]}],
        "oneOf": [{"type": "string"}, {"type": "number"}],
        "not": false,
        "if": {"required": ["name"]},
        "then": {"properties": {"name": {"type": "string"}}},
        "else": true,
        "dependentSchemas": {"name": {"required": ["id"]}},
        "propertyNames": {"minLength": 1},
        "patternProperties": {"^x-": true}
      }
      """#
    ),
    (
      "array and unevaluated keywords",
      #"""
      {
        "prefixItems": [true, {"type": "string"}],
        "items": false,
        "contains": {"type": "integer"},
        "minContains": 0,
        "maxContains": 2,
        "unevaluatedItems": false,
        "unevaluatedProperties": {"type": "boolean"}
      }
      """#
    ),
    (
      "annotations and unrestricted JSON",
      #"""
      {
        "title": "Example",
        "description": "Annotations need not be strings unless specified.",
        "default": {"nested": [null, true, 1, "text"]},
        "examples": [null, false, 42, {}, []],
        "const": {"arbitrary": [1, false]},
        "enum": [null, 1, "two", {"three": true}],
        "deprecated": false,
        "readOnly": true,
        "writeOnly": false,
        "x-extension": [1, {"anything": true}]
      }
      """#
    ),
    (
      "content annotations",
      #"""
      {
        "contentEncoding": "base64",
        "contentMediaType": "application/json",
        "contentSchema": {"type": "object"}
      }
      """#
    ),
    (
      "numeric validation",
      #"""
      {
        "multipleOf": 0.5,
        "minimum": -1,
        "maximum": 10,
        "exclusiveMinimum": 0,
        "exclusiveMaximum": 20,
        "minLength": 0,
        "maxLength": 10,
        "minItems": 0,
        "maxItems": 10,
        "minProperties": 0,
        "maxProperties": 10,
        "uniqueItems": true
      }
      """#
    ),
    (
      "legacy compatibility keywords",
      #"""
      {
        "definitions": {"node": true},
        "dependencies": {"name": ["id"], "id": {"required": ["name"]}}
      }
      """#
    ),
    (
      "core metadata",
      #"""
      {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://example.com/schema",
        "$anchor": "node",
        "$dynamicAnchor": "node",
        "$dynamicRef": "#node",
        "$comment": "No remote request is needed to validate this schema document.",
        "$vocabulary": {"https://json-schema.org/draft/2020-12/vocab/core": true}
      }
      """#
    ),
  ]

  private static let invalidSchemas: [(String, String)] = [
    ("null schema", "null"),
    ("numeric schema", "42"),
    ("string schema value", #""string""#),
    ("array schema value", "[]"),
    ("unknown type name", #"{"type":"not-a-json-type"}"#),
    ("numeric type", #"{"type":42}"#),
    ("empty type union", #"{"type":[]}"#),
    ("duplicate type union", #"{"type":["string","string"]}"#),
    ("invalid type union member", #"{"type":["string",42]}"#),
    ("required must be an array", #"{"required":"name"}"#),
    ("required members must be strings", #"{"required":["name",1]}"#),
    ("required members must be unique", #"{"required":["name","name"]}"#),
    ("properties must be an object", #"{"properties":[]}"#),
    ("nested property must be a schema", #"{"properties":{"child":17}}"#),
    ("nested property type", #"{"properties":{"child":{"type":"invalid"}}}"#),
    ("nested property required shape", #"{"properties":{"child":{"required":true}}}"#),
    ("nested definition type", #"{"$defs":{"child":{"type":42}}}"#),
    ("nested array item type", #"{"items":{"type":42}}"#),
    ("nested additional property type", #"{"additionalProperties":{"type":42}}"#),
    ("nested pattern property type", #"{"patternProperties":{"^x-":{"type":42}}}"#),
    ("nested dependent schema type", #"{"dependentSchemas":{"child":{"type":42}}}"#),
    ("nested allOf required shape", #"{"allOf":[{"required":"name"}]}"#),
    ("nested anyOf type", #"{"anyOf":[{"type":42}]}"#),
    ("nested oneOf type", #"{"oneOf":[{"type":42}]}"#),
    ("nested conditional type", #"{"if":{"type":42}}"#),
    ("nested then type", #"{"then":{"type":42}}"#),
    ("nested else type", #"{"else":{"type":42}}"#),
    ("nested not type", #"{"not":{"type":42}}"#),
    ("nested contains type", #"{"contains":{"type":42}}"#),
    ("nested prefix item type", #"{"prefixItems":[{"type":42}]}"#),
    ("nested propertyNames type", #"{"propertyNames":{"type":42}}"#),
    ("nested unevaluated item type", #"{"unevaluatedItems":{"type":42}}"#),
    ("nested unevaluated property type", #"{"unevaluatedProperties":{"type":42}}"#),
    ("nested content schema type", #"{"contentSchema":{"type":42}}"#),
    ("nested legacy definition type", #"{"definitions":{"child":{"type":42}}}"#),
    ("nested legacy dependency type", #"{"dependencies":{"child":{"type":42}}}"#),
    ("dependentRequired shape", #"{"dependentRequired":{"child":[42]}}"#),
    ("empty allOf", #"{"allOf":[]}"#),
    ("minimum must be numeric", #"{"minimum":"zero"}"#),
    ("multipleOf must be positive", #"{"multipleOf":0}"#),
    ("length must be nonnegative", #"{"minLength":-1}"#),
    ("count must be an integer", #"{"maxItems":1.5}"#),
    ("uniqueItems must be boolean", #"{"uniqueItems":"true"}"#),
    ("title must be a string", #"{"title":42}"#),
    ("examples must be an array", #"{"examples":{}}"#),
    ("deprecated must be boolean", #"{"deprecated":"yes"}"#),
    ("enum must be an array", #"{"enum":{}}"#),
    ("format must be a string", #"{"format":42}"#),
    ("contentEncoding must be a string", #"{"contentEncoding":true}"#),
    ("vocabulary values must be boolean", #"{"$vocabulary":{"https://example.com/vocab":42}}"#),
    ("id must be a string", #"{"$id":42}"#),
    ("id cannot contain a nonempty fragment", #"{"$id":"https://example.com/schema#node"}"#),
    ("anchor must match its pattern", #"{"$anchor":"123 invalid"}"#),
  ]

  private static func schemaDocument(_ relativePath: String) throws -> String {
    guard let directory = Bundle.module.resourceURL else {
      throw ExampleFailure("The schema resource bundle was not available.")
    }
    return try String(
      contentsOf: directory.appendingPathComponent("Schemas").appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }

  private static func expectValidationFailure(_ label: String, instance: String) throws {
    do {
      _ = try MetaSchema.schema.parseAndValidate(instance: instance)
      throw ExampleFailure("\(label) unexpectedly succeeded.")
    } catch let issue as ParseAndValidateIssue {
      switch issue {
      case .validationFailed(let result), .parsingAndValidationFailed(_, let result):
        guard !result.isValid else {
          throw ExampleFailure("\(label) should produce an invalid validation result.")
        }
      case .decodingFailed(let error):
        throw ExampleFailure("\(label) should fail schema validation, not JSON decoding: \(error)")
      case .parsingFailed:
        throw ExampleFailure("\(label) should fail schema validation, not only output parsing.")
      }
    }
  }
}

private struct ExampleFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
