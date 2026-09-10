import Foundation

// The plugin compiles this same source through its SchemaFileNaming.swift symlink.
enum SchemaFileNaming {
  static func typeName(for input: URL) throws -> String {
    let filename = input.lastPathComponent
    let suffix = ".schema.json"
    guard filename.hasSuffix(suffix) else {
      throw NamingError(message: "Expected a filename ending in '.schema.json'.")
    }
    let stem = filename.dropLast(suffix.count)
    let words = stem.split(
      omittingEmptySubsequences: false,
      whereSeparator: { $0 == "-" || $0 == "_" }
    )
    guard
      let first = stem.utf8.first, isLetter(first),
      words.allSatisfy({ !$0.isEmpty }),
      stem.utf8.allSatisfy({ isLetter($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 })
    else {
      throw NamingError(
        message: "The schema basename must start with an ASCII letter and contain only ASCII letters, digits, and single '-' or '_' word separators."
      )
    }
    return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined() + "Schema"
  }

  static func outputName(for typeName: String) -> String {
    "\(typeName).generated.swift"
  }

  private static func isLetter(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte)
  }

  struct NamingError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }
}
