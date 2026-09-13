/// Assigns distinct ASCII Swift labels to an object's ordered JSON property names.
///
/// Existing identifiers are reserved before any replacements are assigned, so an
/// arbitrary key never changes the label of an existing valid key. Labels remain
/// unescaped here; `SchemaSyntax` supplies the escaping required by each context.
enum SchemaPropertyNames {
  static func labels(for names: [String]) -> [String] {
    var used = Set(names.filter(isIdentifier))
    var nextSuffix: [String: Int] = [:]
    return names.map { name in
      guard !isIdentifier(name) else { return name }
      let base = normalized(name)
      var label = base
      var suffix = nextSuffix[base] ?? 2
      while !used.insert(label).inserted {
        label = "\(base)_\(suffix)"
        suffix += 1
      }
      nextSuffix[base] = suffix
      return label
    }
  }

  private static func normalized(_ name: String) -> String {
    var label = ""
    var separator = false
    for scalar in name.unicodeScalars {
      if isContinuation(scalar) {
        if separator && !label.isEmpty { label.append("_") }
        label.unicodeScalars.append(scalar)
        separator = false
      } else {
        separator = true
      }
    }
    if label.isEmpty || label == "_" { return "property" }
    if let first = label.unicodeScalars.first, !isStart(first) {
      label = "_" + label
    }
    return label
  }

  private static func isIdentifier(_ name: String) -> Bool {
    guard name != "_", let first = name.unicodeScalars.first, isStart(first) else {
      return false
    }
    return name.unicodeScalars.dropFirst().allSatisfy(isContinuation)
  }

  private static func isStart(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 65...90, 97...122, 95: true
    default: false
    }
  }

  private static func isContinuation(_ scalar: Unicode.Scalar) -> Bool {
    isStart(scalar) || (48...57).contains(scalar.value)
  }
}
