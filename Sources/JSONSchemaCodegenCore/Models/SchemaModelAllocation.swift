import Foundation

struct SchemaModelAllocation {
  let names: [String: String]
  let cases: [String: String]
  let usedTypeOverrides: Set<String>
  let usedCaseOverrides: Set<String>

  init(
    graph: SchemaModelGraph, options: SchemaGenerationOptions, namespace: String?,
    allowsUnmatchedOverrides: Bool = false
  ) throws {
    var usedTypes = Set<String>()
    var usedCases = Set<String>()
    var owners: [String: String] = [:]
    func override(
      _ table: [String: String], for id: String, provenance: SchemaModelProvenance,
      used: inout Set<String>
    ) throws -> String? {
      var matches: [(String, String)] = []
      for key in table.keys.sorted() {
        let selector = try Self.decodingFragment(key)
        if provenance.origins.contains(where: { origin in
          selector == "#" + origin.pointer
            || selector == origin.resource
            || selector == origin.logicalDocument + "#" + origin.pointer
            || selector == (origin.documentURI?.absoluteString ?? "") + "#" + origin.pointer
        }) {
          matches.append((key, table[key]!))
        }
      }
      guard let first = matches.first else { return nil }
      if Set(matches.map(\.1)).count > 1 {
        throw SchemaGenerationError(
          pointer: provenance.origins[0].pointer,
          message: "Conflicting name overrides resolve to the same model or branch.")
      }
      for (key, _) in matches {
        if let owner = owners[key], owner != id {
          throw SchemaGenerationError(
            pointer: provenance.origins[0].pointer,
            message:
              "Name override '\(key)' is ambiguous across model specializations; use a more specific origin."
          )
        }
        owners[key] = id
        used.insert(key)
      }
      return first.1
    }

    let rootID: String?
    if case .model(let id) = try graph.resolving(graph.root) { rootID = id } else { rootID = nil }
    var requests: [SchemaModelNameRequest] = []
    var explicitTypes = Set<String>()
    for id in graph.definitions.keys.sorted() {
      let definition = graph.definitions[id]!
      let explicit = try override(
        options.names.typeNames, for: id, provenance: definition.provenance, used: &usedTypes)
      if explicit != nil { explicitTypes.insert(id) }
      if id == rootID {
        if let explicit, explicit != "Value" {
          throw SchemaGenerationError(
            pointer: definition.provenance.origins[0].pointer,
            message: "The complete root model has the fixed name 'Value'.")
        }
      } else {
        requests.append(
          .init(
            id: id, preferredName: definition.preferredName, context: definition.context,
            explicitName: explicit, pointer: definition.provenance.origins[0].pointer,
            documentURI: definition.provenance.origins[0].documentURI))
      }
    }
    var reserved: Set<String> = ["Value", "schema", "_schemaWithDefinition"]
    if let namespace { reserved.insert(namespace) }
    var names = try SchemaModelNames.typeNames(for: requests, reserved: reserved)
    if let rootID { names[rootID] = "Value" }
    var cases: [String: String] = [:]
    owners = [:]
    for id in graph.definitions.keys.sorted() {
      if case .stringEnum(let values) = graph.definitions[id]!.shape {
        let requests = try values.map { value in
          SchemaModelNameRequest(
            id: value.id, preferredName: value.rawValue,
            explicitName: try override(
              options.names.caseNames, for: value.id,
              provenance: value.provenance, used: &usedCases),
            pointer: value.provenance.origins[0].pointer,
            documentURI: value.provenance.origins[0].documentURI)
        }
        cases.merge(
          try SchemaModelNames.caseNames(
            for: requests, reserved: ["rawValue", "RawValue", "hash", "hashValue"])
        ) { first, _ in first }
        continue
      }
      guard case .union(let branches) = graph.definitions[id]!.shape else { continue }
      let requests: [SchemaModelNameRequest] = try branches.map { branch in
        var preferred = branch.preferredName
        if !branch.hasDiscriminator, case .model(let payload) = try graph.resolving(branch.type),
          let definition = graph.definitions[payload],
          explicitTypes.contains(payload) || definition.preferredName != "ObjectValue"
        {
          preferred = names[payload] ?? preferred
        }
        return .init(
          id: branch.id, preferredName: preferred,
          explicitName: try override(
            options.names.caseNames, for: branch.id,
            provenance: branch.provenance, used: &usedCases),
          pointer: branch.provenance.origins.last!.pointer,
          documentURI: branch.provenance.origins.last!.documentURI)
      }
      cases.merge(try SchemaModelNames.caseNames(for: requests)) { first, _ in first }
    }
    for (kind, table, used) in [
      ("type", options.names.typeNames, usedTypes), ("case", options.names.caseNames, usedCases),
    ] {
      if !allowsUnmatchedOverrides, let key = Set(table.keys).subtracting(used).sorted().first {
        throw SchemaGenerationError(
          pointer: key.hasPrefix("#") ? String(key.dropFirst()) : key,
          message: "The \(kind)-name override '\(key)' does not resolve to an emitted \(kind).")
      }
    }
    self.names = names
    self.cases = cases
    usedTypeOverrides = usedTypes
    usedCaseOverrides = usedCases
  }

  private static func decodingFragment(_ selector: String) throws -> String {
    guard let separator = selector.firstIndex(of: "#") else { return selector }
    let fragment = selector[selector.index(after: separator)...]
    guard let decoded = fragment.removingPercentEncoding else {
      throw SchemaGenerationError(
        pointer: selector,
        message: "Invalid percent encoding in name-override selector '\(selector)'.")
    }
    // Stored origins already contain canonical JSON Pointer escapes. Decode the
    // URI fragment once, leaving ~0/~1 and literal percent sequences untouched.
    return String(selector[...separator]) + decoded
  }
}
