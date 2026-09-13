/// Swift inline storage dependencies differ from JSON Schema reference dependencies.
struct SchemaModelLayout {
  let indirectEnums: Set<String>
  let classes: Set<String>

  init(graph: SchemaModelGraph, strategy: RecursiveObjectStrategy) throws {
    func dependencies(_ output: SchemaOutput) throws -> Set<String> {
      switch try graph.resolving(output) {
      case .model(let id): return [id]
      case .optional(let wrapped): return try dependencies(wrapped)
      case .tuple(let fields):
        return try fields.reduce(into: Set<String>()) { $0.formUnion(try dependencies($1.type)) }
      default: return []
      }
    }
    var edges: [String: Set<String>] = [:]
    for (id, definition) in graph.definitions {
      let types: [SchemaOutput]
      switch definition.shape {
      case .object(let fields): types = fields.map(\.type)
      case .union(let branches): types = branches.map(\.type)
      case .stringEnum: types = []
      }
      edges[id] = try types.reduce(into: Set<String>()) {
        $0.formUnion(try dependencies($1))
      }
    }
    var indirect = Set<String>()
    for component in Self.cycles(edges) {
      for id in component {
        if case .union = graph.definitions[id]?.shape { indirect.insert(id) }
      }
    }
    for id in indirect { edges[id] = [] }
    let residual = Self.cycles(edges)
    if let cycle = residual.first, strategy == .valueTypes {
      let id = cycle.sorted().first!
      let definition = graph.definitions[id]!
      let origin = definition.provenance.origins[0]
      let detail = cycle.sorted().map {
        let node = graph.definitions[$0]!
        if case .object(let fields) = node.shape,
          let field = fields.first(where: {
            ((try? dependencies($0.type)) ?? []).isDisjoint(with: Set(cycle)) == false
          })
        {
          return node.preferredName + "." + field.name
        }
        return node.preferredName
      }.joined(separator: " -> ")
      throw SchemaGenerationError(
        pointer: origin.pointer,
        message: "Named model has an inline value-layout cycle: \(detail). "
          + "Use recursiveObjects: .immutableClasses to allow immutable reference models.",
        documentURI: origin.documentURI)
    }
    indirectEnums = indirect
    classes = Set(
      residual.flatMap { $0 }.filter {
        if case .object = graph.definitions[$0]?.shape { return true }
        return false
      })
  }

  private static func cycles(_ edges: [String: Set<String>]) -> [[String]] {
    var next = 0
    var indices: [String: Int] = [:]
    var low: [String: Int] = [:]
    var stack: [String] = []
    var active = Set<String>()
    var result: [[String]] = []
    func visit(_ node: String) {
      indices[node] = next
      low[node] = next
      next += 1
      stack.append(node)
      active.insert(node)
      for target in (edges[node] ?? []).sorted() {
        if indices[target] == nil {
          visit(target)
          low[node] = min(low[node]!, low[target]!)
        } else if active.contains(target) {
          low[node] = min(low[node]!, indices[target]!)
        }
      }
      if low[node] == indices[node] {
        var component: [String] = []
        while let member = stack.popLast() {
          active.remove(member)
          component.append(member)
          if member == node { break }
        }
        if component.count > 1 || edges[node]?.contains(node) == true {
          result.append(component.sorted())
        }
      }
    }
    for node in edges.keys.sorted() where indices[node] == nil { visit(node) }
    return result.sorted { $0[0] < $1[0] }
  }
}
