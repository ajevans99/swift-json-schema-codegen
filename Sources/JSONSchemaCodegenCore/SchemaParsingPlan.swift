import OrderedJSON

/// Representation-independent field ordering, key coverage, and presence decisions.
enum SchemaParsingPlan {
  /// A positive finite bound, not a satisfiability calculation. Other constraints
  /// remain in the complete validation schema, even when they exclude some cases.
  struct StringEnum {
    struct Value {
      let rawValue: String
      var indices: [Int]
      var origins: [SchemaModelProvenance.Origin]
    }

    var values: [Value]
    let includesNull: Bool
    let validationValues: [JSONValue]

    static func isApplicable(_ value: JSONValue?) -> Bool {
      guard let entries = value?.array else { return false }
      return entries.contains(where: { $0.string != nil })
        && entries.allSatisfy({ $0.string != nil || $0 == .null })
    }

    init?(_ node: ResolvedSchema) {
      self.init(
        enumValue: node.value.object?["enum"], provenance: SchemaModelGraph.provenance(node))
    }

    init?(enumValue: JSONValue?, provenance: SchemaModelProvenance) {
      guard let entries = enumValue?.array, Self.isApplicable(enumValue)
      else { return nil }
      var values: [Value] = []
      var positions: [[UInt8]: Int] = [:]
      for (index, entry) in entries.enumerated() {
        guard let string = entry.string else { continue }
        // Swift String equality normalizes; JSON equality must not.
        let key = Array(string.utf8)
        if let position = positions[key] {
          values[position].indices.append(index)
        } else {
          positions[key] = values.count
          values.append(Value(rawValue: string, indices: [index], origins: []))
        }
      }
      self.values = values
      includesNull = entries.contains(.null)
      validationValues = entries
      addUseSite(provenance)
    }

    mutating func addUseSite(_ provenance: SchemaModelProvenance) {
      for index in values.indices {
        values[index].origins += provenance.origins.flatMap { origin in
          values[index].indices.map { entry in
            .init(
              pointer: origin.pointer + "/enum/\(entry)", documentURI: origin.documentURI,
              logicalDocument: origin.logicalDocument, resource: origin.resource + "/enum/\(entry)")
          }
        }
      }
    }

    mutating func addOrigins(from other: Self) {
      let origins = Dictionary(
        uniqueKeysWithValues: other.values.map { (Array($0.rawValue.utf8), $0.origins) })
      for index in values.indices {
        values[index].origins += origins[Array(values[index].rawValue.utf8)] ?? []
      }
    }

    static func intersectionBound(in nodes: [ResolvedSchema]) -> Self? {
      var bound: Self?
      for node in nodes {
        guard let candidate = node.stringEnumProjection ?? Self(node) else { continue }
        if bound == nil {
          bound = candidate
        } else {
          bound?.addOrigins(from: candidate)
        }
      }
      return bound
    }
  }

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
