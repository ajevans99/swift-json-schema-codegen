/// Semantic output identity, independent of Swift source spelling and syntax-node identity.
indirect enum SchemaOutput: Hashable, ExpressibleByStringLiteral {
  struct Field: Hashable {
    let name: String
    let type: SchemaOutput
  }

  case named(String)
  case array(SchemaOutput)
  case optional(SchemaOutput)
  case tuple([Field])

  init(stringLiteral value: String) {
    self = .named(value)
  }
}
