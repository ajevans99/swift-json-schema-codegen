import SwiftSyntax
import SwiftSyntaxBuilder

enum SchemaUnknownPropertiesSyntax {
  private static let name = SchemaModelNames.helperPrefix + "PreservingObject"

  static let declaration: DeclSyntax = """
    private struct \(raw: name)<Base: JSONSchemaComponent>: JSONSchemaComponent {
      var schemaValue: SchemaValue
      let upstream: Base
      let modeledKeys: Set<String>
      let additionalKeys: (Base.Output) -> [String]

      init(
        _ upstream: Base, modeledKeys: [String],
        additionalKeys: @escaping (Base.Output) -> [String]
      ) {
        self.schemaValue = upstream.schemaValue
        self.upstream = upstream
        self.modeledKeys = Set(modeledKeys)
        self.additionalKeys = additionalKeys
      }

      func parse(_ value: JSONValue) -> Parsed<(Base.Output, [String: JSONValue]), ParseIssue> {
        guard case .object(let object) = value else {
          return .invalid([.typeMismatch(expected: .object, actual: value)])
        }
        switch upstream.parse(value) {
        case .invalid(let issues):
          return .invalid(issues)
        case .valid(let parsed):
          let excluded = modeledKeys.union(additionalKeys(parsed))
          var unmodeled: [String: JSONValue] = [:]
          for (key, value) in object where !excluded.contains(key) {
            unmodeled[key] = value
          }
          return .valid((parsed, unmodeled))
        }
      }
    }
    """

  static func preserving(
    _ expression: ExprSyntax, keys: [String], hasAdditional: Bool
  ) -> ExprSyntax {
    SchemaSyntax.call(
      SchemaSyntax.reference(name),
      [
        SchemaSyntax.argument(expression),
        SchemaSyntax.argument(
          SchemaSyntax.array(keys.map(SchemaSyntax.stringLiteral)), label: "modeledKeys"),
        SchemaSyntax.argument(
          hasAdditional ? ExprSyntax("{ Array($0.1.matches.keys) }") : ExprSyntax("{ _ in [] }"),
          label: "additionalKeys"),
      ]
    )
  }
}
