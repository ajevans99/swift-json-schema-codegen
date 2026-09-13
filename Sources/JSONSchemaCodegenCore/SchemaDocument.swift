import Foundation

/// A schema and its retrieval URI, supplied explicitly to an offline generation batch.
///
/// The retrieval URI identifies the input even when the document declares a
/// different canonical `$id`. Relative references use the nearest enclosing `$id`,
/// or this URI when no `$id` is present.
public struct SchemaDocument: Sendable {
  public let source: String
  public let retrievalURI: URL
  /// A portable input name used for generated model identities, not reference resolution.
  public let logicalName: String?

  public init(source: String, retrievalURI: URL, logicalName: String? = nil) {
    self.source = source
    self.retrievalURI = retrievalURI
    self.logicalName = logicalName
  }
}
