import Foundation
import JSONSchemaCodegenCore

/// The versioned file format is deliberately separate from Codable's public option shape.
struct CLIConfiguration {
  var options: SchemaGenerationOptions
  let file: URL?
  private let overrideLocations: [String: String]

  init(file: URL?, emittedRootCount: Int) throws {
    self.file = file
    guard let file else {
      options = .init()
      overrideLocations = [:]
      return
    }
    let decoded: ConfigurationFile
    do {
      decoded = try JSONDecoder().decode(ConfigurationFile.self, from: Data(contentsOf: file))
    } catch let error as DecodingError {
      let pointer: String
      let message: String
      switch error {
      case .keyNotFound(let key, let context):
        pointer = Self.pointer(context.codingPath + [key])
        message = "Missing required configuration key '\(key.stringValue)'."
      case .typeMismatch(_, let context), .valueNotFound(_, let context),
        .dataCorrupted(let context):
        pointer = Self.pointer(context.codingPath)
        message = context.debugDescription
      @unknown default:
        pointer = ""
        message = "Invalid configuration."
      }
      throw ConfigurationError(file: file, pointer: pointer, message: message)
    } catch {
      throw ConfigurationError(file: file, pointer: "", message: "\(error)")
    }

    var locations: [String: String] = [:]
    func names(_ values: [String: String], kind: String) throws -> [String: String] {
      var result: [String: String] = [:]
      for selector in values.keys.sorted() {
        let pointer = "/\(kind)/" + Self.escape(selector)
        let name = values[selector]!
        guard isSchemaOverrideIdentifier(name) else {
          throw ConfigurationError(
            file: file, pointer: pointer,
            message: "Override '\(name)' must be an unquoted ASCII Swift identifier."
          )
        }
        let normalized = try Self.normalizedSelector(
          selector, file: file, pointer: pointer, emittedRootCount: emittedRootCount
        )
        guard result[normalized] == nil else {
          throw ConfigurationError(
            file: file, pointer: pointer,
            message: "Multiple selectors resolve to '\(normalized)'."
          )
        }
        result[normalized] = name
        locations["\(kind):\(normalized)"] = pointer
      }
      return result
    }
    options = SchemaGenerationOptions(
      output: decoded.output ?? .tuples,
      recursiveObjects: decoded.recursiveObjects ?? .valueTypes,
      names: .init(
        typeNames: try names(decoded.typeNames ?? [:], kind: "typeNames"),
        caseNames: try names(decoded.caseNames ?? [:], kind: "caseNames")
      )
    )
    overrideLocations = locations
  }

  /// Validate after explicit flags have been applied, and before reading schemas.
  func validate() throws {
    guard options.output == .tuples else { return }
    let pointer: String?
    if options.recursiveObjects != .valueTypes {
      pointer = "/recursiveObjects"
    } else if !options.names.typeNames.isEmpty {
      pointer = "/typeNames"
    } else if !options.names.caseNames.isEmpty {
      pointer = "/caseNames"
    } else {
      pointer = nil
    }
    if let pointer {
      throw ConfigurationError(
        file: file, pointer: pointer,
        message: "This option requires named-model output; use --output-style models."
      )
    }
  }

  func locating(_ error: SchemaGenerationError) -> Error {
    guard let file else { return error }
    let dictionaries = [
      ("typeNames", options.names.typeNames), ("caseNames", options.names.caseNames),
    ]
    for (kind, values) in dictionaries {
      for selector in values.keys.sorted() {
        if error.message.contains(selector) {
          return ConfigurationError(
            file: file, pointer: overrideLocations["\(kind):\(selector)"] ?? "/\(kind)",
            message: error.description
          )
        }
      }
    }
    // Preserve schema diagnostics and attach the configuration origin when the
    // core reports a semantic naming conflict without repeating its selector.
    if error.message.lowercased().contains("override") {
      return ConfigurationError(file: file, pointer: "", message: error.description)
    }
    return error
  }

  private static func normalizedSelector(
    _ selector: String, file: URL, pointer: String, emittedRootCount: Int
  ) throws -> String {
    func failure(_ message: String) -> ConfigurationError {
      ConfigurationError(file: file, pointer: pointer, message: message)
    }
    guard !selector.isEmpty else {
      throw failure("Selectors must not be empty; use '#' for the root.")
    }
    if selector.hasPrefix("#"), emittedRootCount != 1 {
      throw failure(
        "Fragment-only selector '\(selector)' is ambiguous without exactly one emitted root; use a document-qualified selector."
      )
    }
    let pieces = selector.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    if pieces.count == 2 {
      guard let fragment = String(pieces[1]).removingPercentEncoding,
        fragment.isEmpty || fragment.hasPrefix("/")
      else {
        throw failure("Selector '\(selector)' must contain a valid JSON Pointer fragment.")
      }
      let bytes = Array(fragment.utf8)
      for index in bytes.indices where bytes[index] == 126 {
        guard index + 1 < bytes.count, bytes[index + 1] == 48 || bytes[index + 1] == 49 else {
          throw failure("Selector '\(selector)' contains an invalid JSON Pointer '~' escape.")
        }
      }
      guard !pieces[1].contains("#") else {
        throw failure("Selector '\(selector)' contains an unescaped '#'.")
      }
    }
    if selector.hasPrefix("#") { return selector }
    let document = String(pieces[0])
    guard document.removingPercentEncoding != nil, let url = URL(string: document) else {
      throw failure(
        "Selector '\(selector)' contains an invalid document URI; percent-encode path characters.")
    }
    let absolute: URL
    if url.scheme != nil {
      guard URL(string: document, encodingInvalidCharacters: false) != nil else {
        throw failure("Selector '\(selector)' contains an invalid absolute document URI.")
      }
      // Absolute canonical IDs retain their spelling and never trigger network I/O.
      absolute = url.isFileURL ? url.standardizedFileURL : url
    } else {
      guard let resolved = URL(string: document, relativeTo: file.deletingLastPathComponent())
      else {
        throw failure("Cannot resolve selector '\(selector)' relative to the configuration file.")
      }
      absolute = resolved.absoluteURL.standardizedFileURL
    }
    return absolute.absoluteString + (pieces.count == 2 ? "#" + pieces[1] : "")
  }

  private static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }

  private static func pointer(_ path: [any CodingKey]) -> String {
    path.map { "/" + escape($0.stringValue) }.joined()
  }
}

private struct ConfigurationFile: Decodable {
  let output: SchemaOutputStyle?
  let recursiveObjects: RecursiveObjectStrategy?
  let typeNames: [String: String]?
  let caseNames: [String: String]?

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    let known: Set<String> = ["version", "output", "recursiveObjects", "typeNames", "caseNames"]
    for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue })
    where !known.contains(key.stringValue) {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath + [key],
          debugDescription: "Unknown configuration key '\(key.stringValue)'."
        )
      )
    }
    let version = try container.decode(Int.self, forKey: Key("version"))
    guard version == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: Key("version"), in: container,
        debugDescription: "Unsupported configuration version \(version); expected 1."
      )
    }
    // An explicitly present null is a type error, not an omitted setting.
    func optional<T: Decodable>(_ name: String, _: T.Type) throws -> T? {
      let key = Key(name)
      return container.contains(key) ? try container.decode(T.self, forKey: key) : nil
    }
    output = try optional("output", SchemaOutputStyle.self)
    recursiveObjects = try optional("recursiveObjects", RecursiveObjectStrategy.self)
    typeNames = try optional("typeNames", [String: String].self)
    caseNames = try optional("caseNames", [String: String].self)
  }

  private struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
}

struct ConfigurationError: Error, CustomStringConvertible {
  let file: URL?
  let pointer: String
  let message: String

  var description: String {
    "\(file.map { $0.path + ": " } ?? "")#\(pointer): \(message)"
  }
}
