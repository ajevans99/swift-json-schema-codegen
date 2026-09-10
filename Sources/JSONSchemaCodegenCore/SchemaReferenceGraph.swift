import Foundation
import OrderedJSON

struct SchemaLocation: Hashable {
  let document: Int
  let pointer: String

  func child(_ token: String) -> Self {
    Self(
      document: document,
      pointer: pointer + "/" + token.replacingOccurrences(of: "~", with: "~0")
        .replacingOccurrences(of: "/", with: "~1")
    )
  }
}

struct ResolvedSchema {
  var value: JSONValue
  let location: SchemaLocation
  let documentURI: URL?
  var children: [String: ResolvedSchema] = [:]
  var refinements: [ResolvedSchema] = []
  var expandedNodeCount = 1

  func strippingIdentifiers() -> Self {
    var copy = self
    if var object = value.object {
      object.removeValue(forKey: "$id")
      object.removeValue(forKey: "$anchor")
      copy.value = .object(object)
    }
    copy.children = children.mapValues { $0.strippingIdentifiers() }
    copy.refinements = refinements.map { $0.strippingIdentifiers() }
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

  private let documents: [SchemaDocument]
  private let includeDocumentURI: Bool
  private var records: [SchemaLocation: Record] = [:]
  private var resources: [String: SchemaLocation] = [:]
  private var anchors: [Anchor: SchemaLocation] = [:]
  private var resolved: [SchemaLocation: ResolvedSchema] = [:]
  private var stack: [SchemaLocation] = []

  init(documents: [SchemaDocument], includeDocumentURI: Bool = true) throws {
    self.documents = documents
    self.includeDocumentURI = includeDocumentURI
    var parsed: [JSONValue] = []
    for (index, document) in documents.enumerated() {
      let location = SchemaLocation(document: index, pointer: "")
      guard document.retrievalURI.scheme != nil,
        document.retrievalURI.fragment == nil || document.retrievalURI.fragment == ""
      else {
        throw failure(location, "A document retrieval URI must be absolute and have no nonempty fragment.")
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
      try index(
        parsed[documentIndex], at: location, baseURI: documents[documentIndex].retrievalURI,
        resource: location
      )
    }
  }

  func root(at document: Int) throws -> ResolvedSchema {
    try resolve(SchemaLocation(document: document, pointer: ""))
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
        throw failure(location.child("$schema"), "Only the JSON Schema 2020-12 dialect is supported.")
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
        throw failure(location.child("$id"), "'$id' must not contain a nonempty fragment; use '$anchor'.")
      }
      resource = location
      try register(baseURI, at: location, reportingAt: location.child("$id"))
    }
    records[location] = Record(value: value, baseURI: baseURI, resource: resource)
    if let anchorValue = value.object?["$anchor"] {
      guard let anchor = anchorValue.string,
        anchor.range(of: #"^[A-Za-z_][-A-Za-z0-9._]*$"#, options: .regularExpression) != nil
      else {
        throw failure(location.child("$anchor"), "Expected a valid static anchor name.")
      }
      let key = Anchor(resource: resource, name: anchor)
      guard anchors[key] == nil else {
        throw failure(location.child("$anchor"), "Duplicate '$anchor' '\(anchor)' in the same schema resource.")
      }
      anchors[key] = location
    }
    for keyword in ["$defs", "properties"] {
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
    if let items = value.object?["items"] {
      try index(items, at: location.child("items"), baseURI: baseURI, resource: resource)
    }
    if let additional = value.object?["additionalProperties"], additional.object != nil {
      try index(
        additional, at: location.child("additionalProperties"), baseURI: baseURI, resource: resource
      )
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
    _ location: SchemaLocation, referencedFrom referenceLocation: SchemaLocation? = nil
  ) throws -> ResolvedSchema {
    if let cached = resolved[location] { return cached }
    if let cycleStart = stack.firstIndex(of: location) {
      let chain = (Array(stack[cycleStart...]) + [location]).map(label).joined(separator: " -> ")
      throw failure(
        referenceLocation ?? location,
        "Recursive reference cannot be represented by a finite Swift tuple: \(chain)."
      )
    }
    guard stack.count < 128 else {
      throw failure(referenceLocation ?? location, "Schema expansion exceeds the maximum nesting depth of 128.")
    }
    guard let record = records[location] else {
      throw failure(referenceLocation ?? location, "Reference target is not a schema location.")
    }
    stack.append(location)
    defer { stack.removeLast() }

    let result: ResolvedSchema
    if let object = record.value.object, let reference = object["$ref"] {
      guard let reference = reference.string else {
        throw failure(location.child("$ref"), "Expected a string.")
      }
      let target = try referenceTarget(reference, from: location, record: record)
      var referenced = try resolve(target, referencedFrom: location.child("$ref"))
        .strippingIdentifiers()
      var siblings = object
      siblings.removeValue(forKey: "$ref")
      siblings.removeValue(forKey: "$defs")
      // These keywords would change the shape or requiredness of the inferred output.
      for key in ["type", "properties", "items", "required"] where siblings[key] != nil {
        throw failure(
          location.child(key),
          "Structural sibling '\(key)' next to '$ref' is not supported; put it in the referenced schema."
        )
      }
      if !siblings.isEmpty {
        // Applying the same type to the sibling preserves keyword applicability,
        // including null, without pretending that intersecting schemas can be merged.
        if let type = referenced.value.object?["type"] { siblings["type"] = type }
        referenced.refinements.append(
          ResolvedSchema(
            value: .object(siblings), location: location, documentURI: sourceURI(location)
          )
        )
        try accountForExpansion(1, in: &referenced, at: location.child("$ref"))
      }
      result = referenced
    } else {
      var value = record.value
      if var object = value.object {
        object.removeValue(forKey: "$defs")
        value = .object(object)
      }
      var node = ResolvedSchema(value: value, location: location, documentURI: sourceURI(location))
      if let properties = record.value.object?["properties"]?.object {
        for name in properties.keys {
          let child = try resolve(location.child("properties").child(name))
          try accountForExpansion(child.expandedNodeCount, in: &node, at: location)
          node.children["properties/" + name] = child
        }
      }
      if record.value.object?["items"] != nil {
        let items = try resolve(location.child("items"))
        try accountForExpansion(items.expandedNodeCount, in: &node, at: location)
        node.children["items"] = items
      }
      result = node
    }
    resolved[location] = result
    return result
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
    _ reference: String, from location: SchemaLocation, record: Record
  ) throws -> SchemaLocation {
    let errorLocation = location.child("$ref")
    let absolute = try absoluteURI(reference, relativeTo: record.baseURI, at: errorLocation)
    let key = try resourceKey(absolute, at: errorLocation)
    guard let root = resources[key] else {
      throw failure(
        errorLocation,
        "Unresolved reference '\(reference)': resource '\(key)' is not in the supplied document registry. No files or URLs are loaded implicitly."
      )
    }
    let encoded = URLComponents(url: absolute, resolvingAgainstBaseURL: true)?.percentEncodedFragment ?? ""
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
    for encodedToken in fragment.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
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
      throw failure(errorLocation, "Reference '\(reference)' does not point to a schema-bearing location.")
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

  private func absoluteURI(_ text: String, relativeTo base: URL, at location: SchemaLocation) throws -> URL {
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
      throw failure(location, "Cannot resolve URI reference '\(text)' against '\(base.absoluteString)'.")
    }
    return result
  }

  private func resourceKey(_ uri: URL, at location: SchemaLocation) throws -> String {
    guard var components = URLComponents(url: uri.standardized, resolvingAgainstBaseURL: true) else {
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
        let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16)
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
}
