import Foundation
import OrderedJSON

struct SchemaModelProvenance {
  struct Origin: Hashable {
    let pointer: String
    let documentURI: URL?
    let logicalDocument: String
    let resource: String
  }

  let identity: String
  var origins: [Origin]
}

/// Identities stay independent from allocated Swift names and parser adapters.
struct SchemaModelGraph {
  struct Field {
    let key: String?
    let name: String
    let type: SchemaOutput
    let absent: Bool
  }

  struct Branch {
    let id: String
    let type: SchemaOutput
    let preferredName: String
    let provenance: SchemaModelProvenance
    let hasDiscriminator: Bool
  }

  struct StringCase {
    let id: String
    let rawValue: String
    let provenance: SchemaModelProvenance
  }

  enum Shape {
    case object([Field])
    case union([Branch])
    case stringEnum([StringCase])
  }

  struct Definition {
    let id: String
    let shape: Shape
    var provenance: SchemaModelProvenance
    let preferredName: String
    let context: [String]
  }

  var definitions: [String: Definition] = [:]
  var referenceOutputs: [String: SchemaOutput] = [:]
  var referenceProvenances: [String: SchemaModelProvenance] = [:]
  var root: SchemaOutput = .named("JSONValue")
  var rootProvenance: SchemaModelProvenance?

  static func provenance(_ node: ResolvedSchema) -> SchemaModelProvenance {
    node.modelProvenance
      ?? SchemaModelProvenance(
        identity: (node.documentURI?.lastPathComponent ?? "inline.schema.json")
          + "#" + node.location.pointer,
        origins: [
          .init(
            pointer: node.location.pointer, documentURI: node.documentURI,
            logicalDocument: node.documentURI?.lastPathComponent ?? "inline.schema.json",
            resource: (node.documentURI?.lastPathComponent ?? "inline.schema.json")
              + "#" + node.location.pointer)
        ])
  }

  static func tokens(_ pointer: String) -> [String] {
    pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
      $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
  }

  static func specialization(
    of parent: ResolvedSchema, path: [String], constraints: [ResolvedSchema]
  ) -> SchemaModelProvenance {
    let provenance = provenance(parent)
    let suffix = path.map {
      "/"
        + $0.replacingOccurrences(of: "~", with: "~0")
        .replacingOccurrences(of: "/", with: "~1")
    }.joined()
    return .init(
      identity: provenance.identity + suffix + "|intersection:"
        + constraints.map { Self.provenance($0).identity }.joined(separator: ";"),
      origins: provenance.origins.map {
        .init(
          pointer: $0.pointer + suffix, documentURI: $0.documentURI,
          logicalDocument: $0.logicalDocument, resource: $0.resource + suffix)
      })
  }

  static func naming(
    _ provenance: SchemaModelProvenance, object: Bool, fallback: String = "Alternative"
  ) -> (String, [String]) {
    let origin = provenance.origins[0]
    let tokens = tokens(origin.pointer)
    let structure = Set([
      "properties", "$defs", "components", "schemas", "anyOf", "oneOf", "allOf",
      "items", "additionalProperties",
    ])
    let context = tokens.filter { !structure.contains($0) && Int($0) == nil }
    if tokens.count >= 2 && ["$defs", "schemas", "properties"].contains(tokens[tokens.count - 2]) {
      return (tokens.last!, Array(context.dropLast()) + [origin.logicalDocument])
    }
    if tokens.last == "items" {
      return ((context.last ?? "") + "Item", Array(context.dropLast()) + [origin.logicalDocument])
    }
    if tokens.last == "additionalProperties" {
      return ((context.last ?? "") + "Entry", Array(context.dropLast()) + [origin.logicalDocument])
    }
    return (
      object ? "ObjectValue" : context.last ?? fallback, context + [origin.logicalDocument]
    )
  }

  mutating func object(
    at node: ResolvedSchema, fields: [Field]
  ) -> SchemaOutput {
    let provenance = Self.provenance(node)
    let id = provenance.identity + "|object"
    let (name, context) = Self.naming(provenance, object: true)
    insert(
      Definition(
        id: id, shape: .object(fields), provenance: provenance,
        preferredName: name, context: context))
    return .model(id)
  }

  mutating func stringEnum(
    at node: ResolvedSchema, plan: SchemaParsingPlan.StringEnum
  ) -> SchemaOutput {
    let provenance = Self.provenance(node)
    let id = provenance.identity + "|stringEnum"
    let (preferred, context) = Self.naming(provenance, object: false, fallback: "StringValue")
    let cases = plan.values.map { value in
      let caseID = id + "|value:" + value.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
      return StringCase(
        id: caseID, rawValue: value.rawValue,
        provenance: .init(identity: caseID, origins: value.origins))
    }
    insert(
      Definition(
        id: id, shape: .stringEnum(cases), provenance: provenance,
        preferredName: preferred, context: context))
    return .model(id)
  }

  mutating func union(
    at node: ResolvedSchema, keyword: String, outputs: [SchemaFragment],
    schemas: [ResolvedSchema]
  ) -> (SchemaOutput, [String]) {
    let provenance = Self.provenance(node)
    let id = provenance.identity + "|union"
    let (name, context) = Self.naming(provenance, object: false)
    let discriminators = Self.discriminators(schemas)
    let branches = outputs.enumerated().map { index, output in
      let source = schemas[index]
      var branchProvenance = Self.provenance(source)
      // Overrides use branch use-sites, even when its payload is a shared definition.
      for origin in provenance.origins {
        branchProvenance.origins.append(
          .init(
            pointer: origin.pointer + "/\(keyword)/\(index)",
            documentURI: origin.documentURI, logicalDocument: origin.logicalDocument,
            resource: origin.resource + "/\(keyword)/\(index)"))
      }
      let preferred =
        discriminators?[index]
        ?? Self.branchName(output.outputType, schema: source, index: index)
      return Branch(
        id: id + "|branch:\(index)", type: output.outputType,
        preferredName: preferred, provenance: branchProvenance,
        hasDiscriminator: discriminators != nil)
    }
    insert(
      Definition(
        id: id, shape: .union(branches), provenance: provenance,
        preferredName: name, context: context))
    return (.model(id), branches.map(\.id))
  }

  private mutating func insert(_ definition: Definition) {
    if var existing = definitions[definition.id] {
      existing.provenance.origins += definition.provenance.origins
      if case .stringEnum(let oldCases) = existing.shape,
        case .stringEnum(let newCases) = definition.shape
      {
        // Repeated references contribute use-site case selectors as well as type selectors.
        existing = Definition(
          id: existing.id,
          shape: .stringEnum(
            oldCases.map { old in
              var provenance = old.provenance
              provenance.origins +=
                newCases.first(where: { $0.id == old.id })?.provenance.origins ?? []
              return StringCase(id: old.id, rawValue: old.rawValue, provenance: provenance)
            }),
          provenance: existing.provenance, preferredName: existing.preferredName,
          context: existing.context)
      }
      definitions[definition.id] = existing
    } else {
      definitions[definition.id] = definition
    }
  }

  private static func branchName(
    _ output: SchemaOutput, schema: ResolvedSchema, index: Int
  ) -> String {
    let provenance = provenance(schema)
    let tokens = tokens(provenance.origins[0].pointer)
    if tokens.count >= 2, ["$defs", "schemas"].contains(tokens[tokens.count - 2]) {
      return tokens.last!
    }
    switch output {
    case .named("String"): return "string"
    case .named("Int"): return "integer"
    case .named("Double"): return "number"
    case .named("Bool"): return "boolean"
    case .named("Void"): return "null"
    case .named("JSONValue"): return "value"
    case .array: return "array"
    case .dictionary: return "dictionary"
    case .optional: return "nullable"
    case .model:
      if schema.value.object?["type"]?.string == "object" { return "object" }
      return naming(provenance, object: false).0
    default: return "alternative\(index + 1)"
    }
  }

  private static func discriminators(_ schemas: [ResolvedSchema]) -> [String]? {
    guard let first = schemas.first,
      schemas.allSatisfy({ $0.value.object?["type"]?.string == "object" })
    else { return nil }
    for key in (first.value.object?["required"]?.array ?? []).compactMap(\.string) {
      var values: [String] = []
      for schema in schemas {
        guard (schema.value.object?["required"]?.array ?? []).contains(.string(key)),
          let property = schema.children["properties/" + key]?.value.object,
          let value = property["const"]?.string
            ?? (property["enum"]?.array?.count == 1 ? property["enum"]?.array?[0].string : nil)
        else { break }
        values.append(value)
      }
      if values.count == schemas.count, Set(values).count == values.count { return values }
    }
    return nil
  }

  func resolving(_ output: SchemaOutput, visited: Set<String> = []) throws -> SchemaOutput {
    switch output {
    case .recursive(let reference):
      let origin = referenceProvenances[reference]?.origins.first
      guard !visited.contains(reference) else {
        throw SchemaGenerationError(
          pointer: origin?.pointer ?? "",
          message: "Named-model representation cannot express a recursive container alias "
            + "without a nominal object or semantic union. Swift forbids recursive typealiases, "
            + "even through Array or Dictionary; immutableClasses does not change this limitation.",
          documentURI: origin?.documentURI)
      }
      guard let target = referenceOutputs[reference] else {
        throw SchemaGenerationError(
          pointer: origin?.pointer ?? "", message: "Missing recursive parsing output.",
          documentURI: origin?.documentURI)
      }
      return try resolving(target, visited: visited.union([reference]))
    case .array(let item): return .array(try resolving(item, visited: visited))
    case .dictionary(let value): return .dictionary(try resolving(value, visited: visited))
    case .optional(let value): return .optional(try resolving(value, visited: visited))
    case .tuple(let fields):
      return .tuple(
        try fields.map {
          .init(name: $0.name, type: try resolving($0.type, visited: visited))
        })
    default: return output
    }
  }
}
