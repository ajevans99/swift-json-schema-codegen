import OrderedJSON

/// Representation-independent field ordering, key coverage, and presence decisions.
enum SchemaParsingPlan {
  struct Object {
    struct Property {
      let key: String
      let label: String
      let required: Bool
      let schema: ResolvedSchema
    }

    let properties: [Property]
    let additional: ResolvedSchema?
    let preservesCoverage: Bool

    init(_ node: ResolvedSchema) {
      let object = node.value.object ?? [:]
      let declared = object["properties"]?.object ?? [:]
      let required = (object["required"]?.array ?? []).compactMap(\.string)
      let keys = Array(declared.keys) + required.filter { declared[$0] == nil }
      let labels = SchemaPropertyNames.labels(for: keys)
      properties = zip(keys, labels).map { key, label in
        Property(
          key: key, label: label, required: required.contains(key),
          schema: node.children["properties/" + key]
            ?? ResolvedSchema(
              value: .object([:]), location: node.location.child("properties").child(key),
              documentURI: node.documentURI))
      }
      additional =
        object["additionalProperties"]?.object == nil
        ? nil : node.children["additionalProperties"]
      preservesCoverage = keys.count != declared.count || object["patternProperties"] != nil
    }
  }

  struct Union {
    let branches: [SchemaFragment]

    var commonOutput: SchemaOutput? {
      guard let first = branches.first,
        branches.allSatisfy({ $0.outputType == first.outputType })
      else { return nil }
      return first.outputType
    }

    var nullableBranch: Int? {
      guard branches.count == 2,
        let index = branches.firstIndex(where: { $0.outputType == .named("Void") }),
        branches[1 - index].outputType != .named("Void")
      else { return nil }
      return index
    }
  }
}
