import SwiftSyntax
import SwiftSyntaxBuilder

/// Maps semantic model outputs to JSON; never infers shapes from generated Swift.
struct SchemaEncodingSyntax {
  let graph: SchemaModelGraph
  let names: [String: String]
  let cases: [String: String]

  private static let prefix = SchemaModelNames.helperPrefix

  func rootDeclaration(
    name: String, output: SchemaOutput, provenance: SchemaModelProvenance
  ) throws -> DeclSyntax {
    let value = try expression(output, value: "value", provenance: provenance)
    return """
      public static func \(raw: "encode" + name)(_ value: \(raw: name)) throws -> JSONValue {
        return \(value)
      }
      """
  }

  func declarations() throws -> [DeclSyntax] {
    var result: [DeclSyntax] = [
      """
      private struct _JSONSchemaCodegenEncodingError: Swift.Error, Swift.CustomStringConvertible {
        let pointer: String
        let message: String
        var description: String { "#" + pointer + ": " + message }
      }
      """,
      """
      private static func _JSONSchemaCodegenEncodeNumber(
        _ value: Double, pointer: String
      ) throws -> JSONValue {
        guard value.isFinite else {
          throw _JSONSchemaCodegenEncodingError(
            pointer: pointer, message: "Cannot encode a nonfinite number.")
        }
        return .number(value)
      }
      """,
      """
      private static func _JSONSchemaCodegenEncodeOptional<T>(
        _ value: T?, encode: (T) throws -> JSONValue
      ) throws -> JSONValue {
        guard let value else { return .null }
        return try encode(value)
      }
      """,
      """
      private static func _JSONSchemaCodegenEncodeArray<T>(
        _ value: [T], encode: (T) throws -> JSONValue
      ) throws -> JSONValue {
        return .array(try value.map(encode))
      }
      """,
      """
      private static func _JSONSchemaCodegenEncodeDictionary<T>(
        _ value: [String: T], encode: (T) throws -> JSONValue
      ) throws -> JSONValue {
        var object = JSONValue.object([:]).object!
        for (key, value) in value.sorted(by: { $0.key < $1.key }) {
          object[key] = try encode(value)
        }
        return .object(object)
      }
      """,
    ]
    for id in graph.definitions.keys.sorted(by: { names[$0]! < names[$1]! }) {
      let definition = graph.definitions[id]!
      let name = names[id]!
      let body: CodeBlockItemListSyntax
      switch definition.shape {
      case .stringEnum:
        body = ["return .string(value.rawValue)"]
      case .union(let branches):
        var alternatives: [SwitchCaseSyntax] = []
        for branch in branches {
          let caseName = cases[branch.id]!
          let isNull = try graph.resolving(branch.type) == .named("Void")
          let encoded = try expression(
            branch.type, value: "payload", provenance: branch.provenance)
          let guardStatements: CodeBlockItemListSyntax
          if branch.rejectsObjects {
            let pointer = SchemaSyntax.stringLiteral(definition.provenance.origins[0].pointer)
            guardStatements = [
              """
              guard payload.object == nil else {
                throw _JSONSchemaCodegenEncodingError(
                  pointer: \(pointer), message: "The nonObject case cannot contain a JSON object.")
              }
              """
            ]
          } else {
            guardStatements = []
          }
          alternatives.append(
            SwitchCaseSyntax(
              """
              case \(raw: isNull ? ".`\(caseName)`" : ".`\(caseName)`(let payload)"):
                \(SchemaSyntax.formatted(guardStatements))
                return \(encoded)
              """))
        }
        body = [
          CodeBlockItemSyntax(
            item: .expr(
              ExprSyntax(
                SwitchExprSyntax(
                  subject: ExprSyntax("value"),
                  cases: SwitchCaseListSyntax(alternatives.map { .switchCase($0) })))))
        ]
      case .object(let fields):
        if fields.isEmpty {
          body = ["return .object([:])"]
          break
        }
        var statements: [CodeBlockItemSyntax] = [
          "var object = JSONValue.object([:]).object!"
        ]
        for field in fields where field.key != nil {
          let key = field.key!
          let provenance = fieldProvenance(definition.provenance, key: key)
          let access = ExprSyntax("value.\(raw: "`\(field.name)`")")
          let keyLiteral = SchemaSyntax.stringLiteral(key)
          if field.absent {
            guard case .optional(let wrapped) = field.type else {
              throw unsupported(field.type, provenance: provenance)
            }
            let encoded = try expression(wrapped, value: "present", provenance: provenance)
            statements.append(
              """
              if let \(raw: try graph.resolving(wrapped) == .named("Void") ? "_" : "present") = \(access) {
                object[\(keyLiteral)] = \(encoded)
              }
              """)
          } else {
            let encoded = try expression(field.type, value: access, provenance: provenance)
            statements.append("object[\(keyLiteral)] = \(encoded)")
          }
        }
        for field in fields where field.key == nil {
          guard case .dictionary(let item) = try graph.resolving(field.type) else {
            throw unsupported(field.type, provenance: definition.provenance)
          }
          let keys = SchemaSyntax.array(fields.compactMap(\.key).map(SchemaSyntax.stringLiteral))
          let pointer = SchemaSyntax.stringLiteral(definition.provenance.origins[0].pointer)
          let encoded = try expression(item, value: "extra", provenance: definition.provenance)
          statements.append(
            """
            for (key, extra) in value.\(raw: "`\(field.name)`").sorted(by: { $0.key < $1.key }) {
              guard !\(keys).contains(key) else {
                throw _JSONSchemaCodegenEncodingError(
                  pointer: \(pointer),
                  message: "Additional property collides with a modeled JSON key: " + key)
              }
              object[key] = \(encoded)
            }
            """)
        }
        statements.append("return .object(object)")
        body = CodeBlockItemListSyntax(statements)
      }
      result.append(
        DeclSyntax(
          FunctionDeclSyntax(
            modifiers: [
              DeclModifierSyntax(name: .keyword(.private)),
              DeclModifierSyntax(name: .keyword(.static)),
            ],
            name: .identifier(Self.prefix + "Encode" + name),
            signature: FunctionSignatureSyntax(
              parameterClause: FunctionParameterClauseSyntax(parameters: [
                FunctionParameterSyntax(
                  firstName: .wildcardToken(), secondName: .identifier("value"),
                  type: IdentifierTypeSyntax(name: SchemaSyntax.label(name)))
              ]),
              effectSpecifiers: FunctionEffectSpecifiersSyntax(
                throwsClause: ThrowsClauseSyntax(throwsSpecifier: .keyword(.throws))),
              returnClause: ReturnClauseSyntax(type: IdentifierTypeSyntax(name: "JSONValue"))),
            body: CodeBlockSyntax(statements: body))))
    }
    return result
  }

  private func expression(
    _ output: SchemaOutput, value: ExprSyntax, provenance: SchemaModelProvenance
  ) throws -> ExprSyntax {
    let pointer = SchemaSyntax.stringLiteral(provenance.origins[0].pointer)
    switch try graph.resolving(output) {
    case .named("String"): return ".string(\(value))"
    case .named("Int"): return ".integer(\(value))"
    case .named("Bool"): return ".boolean(\(value))"
    case .named("Void"): return ".null"
    case .named("Double"):
      return "try Self._JSONSchemaCodegenEncodeNumber(\(value), pointer: \(pointer))"
    case .named("JSONValue"): return value
    case .model(let id):
      guard let name = names[id] else { throw unsupported(output, provenance: provenance) }
      return "try Self.\(raw: Self.prefix + "Encode" + name)(\(value))"
    case .optional(let wrapped):
      let encoded = try expression(wrapped, value: "element", provenance: provenance)
      return "try Self._JSONSchemaCodegenEncodeOptional(\(value)) { element in \(encoded) }"
    case .array(let item):
      let encoded = try expression(item, value: "element", provenance: provenance)
      return "try Self._JSONSchemaCodegenEncodeArray(\(value)) { element in \(encoded) }"
    case .dictionary(let item):
      let encoded = try expression(item, value: "element", provenance: provenance)
      return "try Self._JSONSchemaCodegenEncodeDictionary(\(value)) { element in \(encoded) }"
    default:
      throw unsupported(output, provenance: provenance)
    }
  }

  private func unsupported(
    _ output: SchemaOutput, provenance: SchemaModelProvenance
  ) -> SchemaGenerationError {
    .init(
      pointer: provenance.origins[0].pointer,
      message: "No model-to-JSON encoding is supported for output \(output).",
      documentURI: provenance.origins[0].documentURI)
  }

  private func fieldProvenance(
    _ provenance: SchemaModelProvenance, key: String
  ) -> SchemaModelProvenance {
    let suffix =
      "/properties/"
      + key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    return .init(
      identity: provenance.identity + suffix,
      origins: provenance.origins.map {
        .init(
          pointer: $0.pointer + suffix, documentURI: $0.documentURI,
          logicalDocument: $0.logicalDocument, resource: $0.resource + suffix)
      })
  }
}
