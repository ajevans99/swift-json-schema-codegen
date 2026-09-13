import Foundation
import OrderedJSON

struct SchemaLocation: Hashable {
  let document: Int
  let pointer: String

  func child(_ token: String) -> Self {
    Self(
      document: document,
      pointer: pointer + "/"
        + token.replacingOccurrences(of: "~", with: "~0")
        .replacingOccurrences(of: "/", with: "~1")
    )
  }
}

indirect enum SchemaReferenceApplication {
  case reference(targets: [ResolvedSchema], siblings: ResolvedSchema)
}

struct ResolvedSchema {
  var value: JSONValue
  let location: SchemaLocation
  let documentURI: URL?
  var children: [String: ResolvedSchema] = [:]
  var refinements: [ResolvedSchema] = []
  var expandedNodeCount = 1
  var reference: String?
  var recursiveDefinitions: [String: ResolvedSchema] = [:]
  var referenceApplication: SchemaReferenceApplication?
  var modelProvenance: SchemaModelProvenance?
  var stringEnumProjection: SchemaParsingPlan.StringEnum?

  /// A self-contained validation schema, preserving conjunction boundaries.
  var validationValue: JSONValue {
    var value = value
    if var object = value.object {
      for keyword in SchemaKeywords.maps where keyword != "$defs" {
        if var properties = object[keyword]?.object {
          for name in properties.keys {
            if let child = children[keyword + "/" + name] {
              properties[name] = child.validationValue
            }
          }
          object[keyword] = .object(properties)
        }
      }
      for keyword in SchemaKeywords.singles where object[keyword] != nil {
        if let child = children[keyword] { object[keyword] = child.validationValue }
      }
      for keyword in SchemaKeywords.arrays {
        if let branches = object[keyword]?.array {
          object[keyword] = .array(
            branches.indices.map {
              children["\(keyword)/\($0)"]?.validationValue ?? branches[$0]
            })
        }
      }
      value = .object(object)
    }
    var result: JSONValue =
      refinements.isEmpty
      ? value
      : .object(["allOf": .array([value] + refinements.map(\.validationValue))])
    if reference != nil, !refinements.isEmpty, var object = value.object {
      object["allOf"] = .array(refinements.map(\.validationValue))
      result = .object(object)
    }
    if case .reference(let targets, let siblings) = referenceApplication {
      // Reference siblings share annotations with the referenced schemas.
      // Putting the siblings in a separate allOf branch changes unevaluated*.
      var object = siblings.validationValue.object ?? [:]
      object["allOf"] = .array(
        targets.map(\.validationValue) + (object["allOf"]?.array ?? []))
      result = .object(object)
    }
    if !recursiveDefinitions.isEmpty {
      var object = result.object ?? ["allOf": .array([result])]
      var definitions = object["$defs"]?.object ?? [:]
      for name in recursiveDefinitions.keys.sorted() {
        definitions["__codegen_" + name] = recursiveDefinitions[name]?.validationValue
      }
      object["$defs"] = .object(definitions)
      result = .object(object)
    }
    return result
  }

  func strippingIdentifiers() -> Self {
    var copy = self
    if var object = value.object {
      object.removeValue(forKey: "$id")
      object.removeValue(forKey: "$anchor")
      object.removeValue(forKey: "$dynamicAnchor")
      copy.value = .object(object)
    }
    copy.children = children.mapValues { $0.strippingIdentifiers() }
    copy.refinements = refinements.map { $0.strippingIdentifiers() }
    if case .reference(let targets, let siblings) = referenceApplication {
      copy.referenceApplication = .reference(
        targets: targets.map { $0.strippingIdentifiers() },
        siblings: siblings.strippingIdentifiers()
      )
    }
    return copy
  }
}

/// A compile-time registry of raw schema locations, not runtime validator schemas.
///
/// Only schema-bearing keywords are indexed. Objects in annotations such as
/// `default` and `examples` must not register identifiers or become ref targets.
final class SchemaReferenceGraph {
  private struct Record {
    let value: JSONValue
    let baseURI: URL
    let resource: SchemaLocation
  }

  private struct Anchor: Hashable {
    let resource: SchemaLocation
    let name: String
  }

  private struct Resolution: Hashable {
    let location: SchemaLocation
    let scope: [String: SchemaLocation]
  }

  private let documents: [SchemaDocument]
  private let includeDocumentURI: Bool
  private var records: [SchemaLocation: Record] = [:]
  private var resources: [String: SchemaLocation] = [:]
  private var anchors: [Anchor: SchemaLocation] = [:]
  private var dynamicAnchors: [Anchor: SchemaLocation] = [:]
  private var resolved: [Resolution: ResolvedSchema] = [:]
  private var stack: [(resolution: Resolution, instanceDepth: Int)] = []
  private var referenceNames: [Resolution: String] = [:]

  init(
    documents: [SchemaDocument], includeDocumentURI: Bool = true,
    schemaPointers: [String]? = nil
  ) throws {
    self.documents = documents
    self.includeDocumentURI = includeDocumentURI
    var parsed: [JSONValue] = []
    for (index, document) in documents.enumerated() {
      let location = SchemaLocation(document: index, pointer: "")
      guard document.retrievalURI.scheme != nil,
        document.retrievalURI.fragment == nil || document.retrievalURI.fragment == ""
      else {
        throw failure(
          location, "A document retrieval URI must be absolute and have no nonempty fragment.")
      }
      do {
        parsed.append(try JSONValue.parse(document.source))
      } catch let error as JSONParseError {
        throw failure(
          location,
          "Invalid JSON at line \(error.line), column \(error.column): \(error.message)"
        )
      }
      try register(document.retrievalURI, at: location, reportingAt: location)
    }
    for documentIndex in documents.indices.sorted(by: {
      documents[$0].retrievalURI.absoluteString < documents[$1].retrievalURI.absoluteString
    }) {
      let location = SchemaLocation(document: documentIndex, pointer: "")
      if let schemaPointers {
        let baseURI = documents[documentIndex].retrievalURI
        records[location] = Record(
          value: parsed[documentIndex], baseURI: baseURI, resource: location)
        for pointer in schemaPointers {
          let target = SchemaLocation(document: documentIndex, pointer: pointer)
          let value = try value(at: pointer, in: parsed[documentIndex], reportingAt: target)
          try index(value, at: target, baseURI: baseURI, resource: location)
        }
      } else {
        try index(
          parsed[documentIndex], at: location, baseURI: documents[documentIndex].retrievalURI,
          resource: location
        )
      }
    }
  }

  func root(at document: Int) throws -> ResolvedSchema {
    try generation(at: SchemaLocation(document: document, pointer: ""))
  }

  func schema(at pointer: String) throws -> ResolvedSchema {
    try generation(at: SchemaLocation(document: 0, pointer: pointer))
  }

  private func generation(at location: SchemaLocation) throws -> ResolvedSchema {
    resolved.removeAll()
    referenceNames.removeAll()
    var root = try resolve(location)
    for (resolution, name) in referenceNames {
      guard let definition = resolved[resolution] else {
        throw failure(resolution.location, "Missing recursive schema definition.")
      }
      root.recursiveDefinitions[name] = definition.strippingIdentifiers()
    }
    if !root.recursiveDefinitions.isEmpty { root = root.strippingIdentifiers() }
    return root
  }

  private func value(
    at pointer: String, in document: JSONValue, reportingAt location: SchemaLocation
  ) throws -> JSONValue {
    guard pointer.hasPrefix("/") else {
      throw failure(location, "Expected a nonempty JSON Pointer to a schema.")
    }
    var value = document
    for part in pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      let token = try pointerToken(String(part), at: location)
      guard let next = value.object?[token] else {
        throw failure(location, "Schema pointer does not exist in the document.")
      }
      value = next
    }
    return value
  }

  private func index(
    _ value: JSONValue,
    at location: SchemaLocation,
    baseURI inheritedURI: URL,
    resource inheritedResource: SchemaLocation
  ) throws {
    guard value.object != nil || value.boolean != nil else {
      throw failure(location, "Expected a schema object or boolean.")
    }
    if let dialect = value.object?["$schema"] {
      guard dialect.string == "https://json-schema.org/draft/2020-12/schema" else {
        throw failure(
          location.child("$schema"), "Only the JSON Schema 2020-12 dialect is supported.")
      }
    }
    var baseURI = inheritedURI
    var resource = inheritedResource
    if let idValue = value.object?["$id"] {
      guard let id = idValue.string else {
        throw failure(location.child("$id"), "Expected a string.")
      }
      baseURI = try absoluteURI(id, relativeTo: inheritedURI, at: location.child("$id"))
      guard baseURI.fragment == nil || baseURI.fragment == "" else {
        throw failure(
          location.child("$id"), "'$id' must not contain a nonempty fragment; use '$anchor'.")
      }
      resource = location
      try register(baseURI, at: location, reportingAt: location.child("$id"))
    }
    records[location] = Record(value: value, baseURI: baseURI, resource: resource)
    for keyword in ["$anchor", "$dynamicAnchor"] {
      guard let anchorValue = value.object?[keyword] else { continue }
      guard let anchor = anchorValue.string,
        anchor.range(of: #"^[A-Za-z_][-A-Za-z0-9._]*$"#, options: .regularExpression) != nil
      else {
        throw failure(
          location.child(keyword),
          keyword == "$anchor"
            ? "Expected a valid static anchor name." : "Expected a valid dynamic anchor name.")
      }
      let key = Anchor(resource: resource, name: anchor)
      guard anchors[key] == nil || anchors[key] == location else {
        throw failure(
          location.child(keyword), "Duplicate '\(keyword)' '\(anchor)' in the same schema resource."
        )
      }
      anchors[key] = location
      if keyword == "$dynamicAnchor" { dynamicAnchors[key] = location }
    }
    for keyword in SchemaKeywords.maps {
      if let children = value.object?[keyword] {
        guard let children = children.object else {
          throw failure(location.child(keyword), "'\(keyword)' must be an object.")
        }
        for (name, child) in children {
          try index(
            child, at: location.child(keyword).child(name), baseURI: baseURI, resource: resource
          )
        }
      }
    }
    for keyword in SchemaKeywords.arrays {
      if let raw = value.object?[keyword] {
        guard let branches = raw.array, !branches.isEmpty else {
          throw failure(
            location.child(keyword), "'\(keyword)' must be a nonempty array of schemas.")
        }
        for (offset, branch) in branches.enumerated() {
          try index(
            branch, at: location.child(keyword).child(String(offset)),
            baseURI: baseURI, resource: resource
          )
        }
      }
    }
    for keyword in SchemaKeywords.singles {
      if let child = value.object?[keyword] {
        try index(child, at: location.child(keyword), baseURI: baseURI, resource: resource)
      }
    }
  }

  private func register(
    _ uri: URL, at location: SchemaLocation, reportingAt errorLocation: SchemaLocation
  ) throws {
    let key = try resourceKey(uri, at: errorLocation)
    if let existing = resources[key], existing != location {
      throw failure(
        errorLocation,
        "Duplicate schema resource URI '\(key)' (already registered at \(label(existing)))."
      )
    }
    resources[key] = location
  }

  private func resolve(
    _ location: SchemaLocation, referencedFrom referenceLocation: SchemaLocation? = nil,
    scope inheritedScope: [String: SchemaLocation] = [:], instanceDepth: Int = 0
  ) throws -> ResolvedSchema {
    guard let record = records[location] else {
      throw failure(referenceLocation ?? location, "Reference target is not a schema location.")
    }
    var scope = inheritedScope
    for (anchor, target) in dynamicAnchors where anchor.resource == record.resource {
      if scope[anchor.name] == nil { scope[anchor.name] = target }
    }
    let resolution = Resolution(location: location, scope: scope)
    if let cached = resolved[resolution] { return cached }
    if let cycleStart = stack.firstIndex(where: { $0.resolution == resolution }) {
      guard instanceDepth > stack[cycleStart].instanceDepth else {
        let chain = (stack[cycleStart...].map(\.resolution.location) + [location])
          .map(label).joined(separator: " -> ")
        throw failure(
          referenceLocation ?? location,
          "Recursive reference makes no instance progress and would evaluate indefinitely: \(chain)."
        )
      }
      let name: String
      if let existing = referenceNames[resolution] {
        name = existing
      } else {
        name = "Reference\(referenceNames.count + 1)"
        referenceNames[resolution] = name
      }
      return ResolvedSchema(
        value: .object(["$ref": .string("#/$defs/__codegen_" + name)]),
        location: location, documentURI: sourceURI(location), reference: name,
        modelProvenance: provenance(for: resolution))
    }
    guard stack.count < 128 else {
      throw failure(
        referenceLocation ?? location, "Schema expansion exceeds the maximum nesting depth of 128.")
    }
    stack.append((resolution, instanceDepth))
    defer { stack.removeLast() }

    var result: ResolvedSchema
    if let object = record.value.object, object["$ref"] != nil || object["$dynamicRef"] != nil {
      var references: [ResolvedSchema] = []
      for keyword in ["$ref", "$dynamicRef"] {
        guard let value = object[keyword] else { continue }
        guard let reference = value.string else {
          throw failure(location.child(keyword), "Expected a string.")
        }
        var target = try referenceTarget(
          reference, from: location, record: record, keyword: keyword)
        if keyword == "$dynamicRef",
          let anchor = records[target]?.value.object?["$dynamicAnchor"]?.string,
          let fragment = URLComponents(string: reference)?.percentEncodedFragment?
            .removingPercentEncoding,
          fragment == anchor, let dynamicTarget = scope[anchor]
        {
          target = dynamicTarget
        }
        references.append(
          try resolve(
            target, referencedFrom: location.child(keyword), scope: scope,
            instanceDepth: instanceDepth
          )
          .strippingIdentifiers())
      }
      guard var referenced = references.first else {
        throw failure(location, "Missing schema reference.")
      }
      referenced.refinements.append(contentsOf: references.dropFirst())
      var siblings = object
      siblings.removeValue(forKey: "$ref")
      siblings.removeValue(forKey: "$dynamicRef")
      siblings.removeValue(forKey: "$defs")
      siblings.removeValue(forKey: "$dynamicAnchor")
      if !siblings.isEmpty || references.count > 1 {
        let sibling = try resolveChildren(
          ResolvedSchema(
            value: .object(siblings), location: location, documentURI: sourceURI(location),
            modelProvenance: provenance(for: resolution)),
          scope: scope, instanceDepth: instanceDepth
        )
        referenced.refinements.append(sibling)
        referenced.referenceApplication = .reference(targets: references, siblings: sibling)
        try accountForExpansion(
          sibling.expandedNodeCount, in: &referenced, at: location)
      }
      result = referenced
      let origin = provenance(for: resolution)
      if siblings.keys.contains(where: {
        [
          "type", "properties", "required", "items", "prefixItems", "additionalProperties",
          "allOf", "anyOf", "oneOf",
        ].contains($0)
      }) || SchemaParsingPlan.StringEnum.isApplicable(siblings["enum"]) || references.count > 1 {
        result.modelProvenance = origin
      } else if var provenance = result.modelProvenance {
        provenance.origins += origin.origins
        result.modelProvenance = provenance
      }
      if var stringEnum = result.stringEnumProjection {
        if siblings["enum"] == nil {
          stringEnum.addUseSite(origin)
        } else if let siblingEnum = SchemaParsingPlan.StringEnum(
          enumValue: siblings["enum"], provenance: origin)
        {
          // A sibling's enum indices address its own values, not the base bound's order.
          stringEnum.addOrigins(from: siblingEnum)
        }
        result.stringEnumProjection = stringEnum
      }
    } else {
      var value = record.value
      if var object = value.object {
        object.removeValue(forKey: "$defs")
        object.removeValue(forKey: "$dynamicAnchor")
        value = .object(object)
      }
      result = try resolveChildren(
        ResolvedSchema(value: value, location: location, documentURI: sourceURI(location)),
        scope: scope, instanceDepth: instanceDepth
      )
      result.modelProvenance = provenance(for: resolution)
      result.stringEnumProjection = SchemaParsingPlan.StringEnum(result)
    }
    resolved[resolution] = result
    return result
  }

  private func resolveChildren(
    _ input: ResolvedSchema, scope: [String: SchemaLocation], instanceDepth: Int
  ) throws -> ResolvedSchema {
    var node = input
    let location = node.location
    for keyword in SchemaKeywords.maps where keyword != "$defs" {
      if let properties = node.value.object?[keyword]?.object {
        for name in properties.keys {
          let child = try resolve(
            location.child(keyword).child(name), scope: scope,
            instanceDepth: instanceDepth + (keyword == "dependentSchemas" ? 0 : 1))
          try accountForExpansion(child.expandedNodeCount, in: &node, at: location)
          node.children[keyword + "/" + name] = child
        }
      }
    }
    for keyword in SchemaKeywords.singles where node.value.object?[keyword] != nil {
      let descends = [
        "items", "additionalProperties", "propertyNames", "contains",
        "unevaluatedItems", "unevaluatedProperties", "contentSchema",
      ].contains(keyword)
      let child = try resolve(
        location.child(keyword), scope: scope, instanceDepth: instanceDepth + (descends ? 1 : 0))
      try accountForExpansion(child.expandedNodeCount, in: &node, at: location)
      node.children[keyword] = child
    }
    for keyword in SchemaKeywords.arrays {
      if let branches = node.value.object?[keyword]?.array {
        for offset in branches.indices {
          let child = try resolve(
            location.child(keyword).child(String(offset)), scope: scope,
            instanceDepth: instanceDepth + (keyword == "prefixItems" ? 1 : 0))
          try accountForExpansion(child.expandedNodeCount, in: &node, at: location)
          node.children["\(keyword)/\(offset)"] = child
        }
      }
    }
    return node
  }

  private func accountForExpansion(
    _ count: Int, in node: inout ResolvedSchema, at location: SchemaLocation
  ) throws {
    guard node.expandedNodeCount <= 10_000 - count else {
      throw failure(location, "Schema expansion exceeds the maximum of 10000 emitted nodes.")
    }
    node.expandedNodeCount += count
  }

  private func referenceTarget(
    _ reference: String, from location: SchemaLocation, record: Record, keyword: String = "$ref"
  ) throws -> SchemaLocation {
    let errorLocation = location.child(keyword)
    let absolute = try absoluteURI(reference, relativeTo: record.baseURI, at: errorLocation)
    let key = try resourceKey(absolute, at: errorLocation)
    guard let root = resources[key] else {
      throw failure(
        errorLocation,
        "Unresolved reference '\(reference)': resource '\(key)' is not in the supplied document registry. No files or URLs are loaded implicitly."
      )
    }
    let encoded =
      URLComponents(url: absolute, resolvingAgainstBaseURL: true)?.percentEncodedFragment ?? ""
    guard let fragment = encoded.removingPercentEncoding else {
      throw failure(errorLocation, "Invalid percent encoding in reference fragment.")
    }
    if fragment.isEmpty { return root }
    if !fragment.hasPrefix("/") {
      guard let target = anchors[Anchor(resource: root, name: fragment)] else {
        throw failure(errorLocation, "Unresolved anchor '#\(fragment)' in resource '\(key)'.")
      }
      return target
    }
    guard var value = records[root]?.value else {
      throw failure(errorLocation, "Unresolved schema resource '\(key)'.")
    }
    var target = root
    for encodedToken in fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    {
      let token = try pointerToken(String(encodedToken), at: errorLocation)
      if let object = value.object, let child = object[token] {
        value = child
      } else if let array = value.array, !token.isEmpty,
        token.utf8.allSatisfy({ (48...57).contains($0) }),
        token == "0" || !token.hasPrefix("0"),
        let index = Int(token), array.indices.contains(index)
      {
        value = array[index]
      } else {
        throw failure(errorLocation, "Unresolved JSON Pointer in reference '\(reference)'.")
      }
      target = target.child(token)
    }
    guard records[target] != nil else {
      throw failure(
        errorLocation, "Reference '\(reference)' does not point to a schema-bearing location.")
    }
    return target
  }

  private func pointerToken(_ encoded: String, at location: SchemaLocation) throws -> String {
    var decoded = ""
    var iterator = encoded.makeIterator()
    while let character = iterator.next() {
      if character != "~" {
        decoded.append(character)
      } else {
        switch iterator.next() {
        case "0": decoded.append("~")
        case "1": decoded.append("/")
        default: throw failure(location, "Invalid JSON Pointer escape; expected '~0' or '~1'.")
        }
      }
    }
    return decoded
  }

  private func absoluteURI(_ text: String, relativeTo base: URL, at location: SchemaLocation) throws
    -> URL
  {
    guard URL(string: text, encodingInvalidCharacters: false) != nil else {
      throw failure(location, "Invalid URI reference '\(text)'.")
    }
    // Foundation's relative URL handling is inconsistent for opaque URIs such as
    // URNs. A fragment always refers to the same resource, regardless of scheme.
    if text.isEmpty || text.hasPrefix("#") {
      guard var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
        throw failure(location, "Invalid base URI '\(base.absoluteString)'.")
      }
      components.percentEncodedFragment = text.isEmpty ? nil : String(text.dropFirst())
      guard let result = components.url else {
        throw failure(location, "Invalid URI reference '\(text)'.")
      }
      return result
    }
    guard let result = URL(string: text, relativeTo: base)?.absoluteURL, result.scheme != nil else {
      throw failure(
        location, "Cannot resolve URI reference '\(text)' against '\(base.absoluteString)'.")
    }
    return result
  }

  private func resourceKey(_ uri: URL, at location: SchemaLocation) throws -> String {
    guard var components = URLComponents(url: uri.standardized, resolvingAgainstBaseURL: true)
    else {
      throw failure(location, "Invalid schema resource URI '\(uri.absoluteString)'.")
    }
    components.fragment = nil
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    if components.percentEncodedPath.isEmpty,
      components.scheme == "http" || components.scheme == "https"
    {
      components.percentEncodedPath = "/"
    }
    if (components.scheme == "https" && components.port == 443)
      || (components.scheme == "http" && components.port == 80)
    {
      components.port = nil
    }
    guard let key = components.url?.absoluteString else {
      throw failure(location, "Invalid schema resource URI '\(uri.absoluteString)'.")
    }
    let normalized = normalizePercentEncoding(key)
    guard let result = URL(string: normalized, encodingInvalidCharacters: false) else {
      throw failure(location, "Invalid schema resource URI '\(uri.absoluteString)'.")
    }
    return result.standardized.absoluteString
  }

  private func normalizePercentEncoding(_ value: String) -> String {
    let bytes = Array(value.utf8)
    var result = ""
    var index = 0
    while index < bytes.count {
      if bytes[index] == 37, index + 2 < bytes.count,
        let byte = UInt8(
          String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16)
      {
        if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
          || [45, 46, 95, 126].contains(byte)
        {
          result.unicodeScalars.append(UnicodeScalar(byte))
        } else {
          result += String(format: "%%%02X", byte)
        }
        index += 3
      } else {
        result.unicodeScalars.append(UnicodeScalar(bytes[index]))
        index += 1
      }
    }
    return result
  }

  private func sourceURI(_ location: SchemaLocation) -> URL? {
    includeDocumentURI ? documents[location.document].retrievalURI : nil
  }

  private func label(_ location: SchemaLocation) -> String {
    let source = sourceURI(location).map(\.absoluteString) ?? ""
    return source + "#" + location.pointer
  }

  private func failure(_ location: SchemaLocation, _ message: String) -> SchemaGenerationError {
    SchemaGenerationError(
      pointer: location.pointer, message: message, documentURI: sourceURI(location)
    )
  }

  private func provenance(for resolution: Resolution) -> SchemaModelProvenance {
    func identity(_ location: SchemaLocation) -> String {
      let record = records[location]
      let resourceURI = record?.baseURI
      let source =
        resourceURI?.isFileURL == false
        ? resourceURI!.absoluteString
        : logicalName(for: location.document)
      let resourcePointer = record?.resource.pointer ?? ""
      let pointer =
        resourceURI?.isFileURL == false
        ? String(location.pointer.dropFirst(resourcePointer.count)) : location.pointer
      return source + "#" + pointer
    }
    let scope = resolution.scope.keys.sorted().map {
      $0 + "=" + identity(resolution.scope[$0]!)
    }.joined(separator: "&")
    let source = identity(resolution.location)
    return SchemaModelProvenance(
      identity: source + (scope.isEmpty ? "" : "|scope:" + scope),
      origins: [
        .init(
          pointer: resolution.location.pointer, documentURI: sourceURI(resolution.location),
          logicalDocument: logicalName(for: resolution.location.document),
          resource: source)
      ])
  }

  private func logicalName(for index: Int) -> String {
    if let logicalName = documents[index].logicalName { return logicalName }
    let components = documents[index].retrievalURI.pathComponents
    for count in 1...max(components.count, 1) {
      let candidate = components.suffix(count).joined(separator: "/")
      if !documents.indices.contains(where: {
        $0 != index && documents[$0].logicalName == nil
          && documents[$0].retrievalURI.pathComponents.suffix(count).joined(separator: "/")
            == candidate
      }) {
        return candidate
      }
    }
    return documents[index].retrievalURI.lastPathComponent
  }
}
