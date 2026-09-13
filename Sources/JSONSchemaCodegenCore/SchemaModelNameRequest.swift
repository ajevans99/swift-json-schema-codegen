import Foundation

/// Resolved naming evidence for a model or union case, independent of graph traversal.
struct SchemaModelNameRequest: Equatable, Sendable {
  let id: String
  let preferredName: String
  /// Nearest-first ancestor, definition, or portable logical document names.
  let context: [String]
  let explicitName: String?
  let pointer: String
  let documentURI: URL?

  init(
    id: String,
    preferredName: String,
    context: [String] = [],
    explicitName: String? = nil,
    pointer: String = "",
    documentURI: URL? = nil
  ) {
    self.id = id
    self.preferredName = preferredName
    self.context = context
    self.explicitName = explicitName
    self.pointer = pointer
    self.documentURI = documentURI
  }
}
