import JSONSchemaCodegenCore
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct SchemaMacro: MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let namespace = declaration.as(EnumDeclSyntax.self) else {
      throw diagnostic(
        at: node,
        id: "enum-required",
        message: "@Schema can only be attached to an empty namespace enum."
      )
    }
    let lexicalContext = [Syntax(namespace)] + context.lexicalContext
    guard !lexicalContext.contains(where: { syntax in
      if let generic = syntax.asProtocol(WithGenericParametersSyntax.self) {
        return generic.genericParameterClause != nil || generic.genericWhereClause != nil
      }
      return syntax.as(ExtensionDeclSyntax.self)?.genericWhereClause != nil
    }) else {
      throw diagnostic(
        at: node,
        id: "generic-context",
        message: "@Schema requires a non-generic enum outside generic contexts."
      )
    }
    guard !namespace.memberBlock.members.contains(where: { declaresSchema($0.decl) }) else {
      throw diagnostic(
        at: node,
        id: "name-conflict",
        message: "@Schema cannot generate 'schema' because the enum already declares that name."
      )
    }
    guard namespace.memberBlock.members.isEmpty else {
      throw diagnostic(
        at: node,
        id: "empty-enum-required",
        message: "@Schema requires an empty namespace enum; remove its existing members."
      )
    }
    let schemaAttributes = namespace.attributes.compactMap { $0.as(AttributeSyntax.self) }
      .filter {
        $0.attributeName.as(IdentifierTypeSyntax.self)?.name.text == "Schema"
          || $0.attributeName.as(MemberTypeSyntax.self)?.name.text == "Schema"
      }
    guard schemaAttributes.count == 1 else {
      throw diagnostic(
        at: node,
        id: "duplicate-attribute",
        message: "@Schema may only be applied once to an enum."
      )
    }
    guard case .argumentList(let arguments) = node.arguments,
      arguments.count == 1, let argument = arguments.first,
      argument.label == nil
    else {
      throw diagnostic(
        at: node,
        id: "arguments",
        message: "@Schema requires exactly one unlabeled string literal."
      )
    }
    guard let literal = argument.expression.as(StringLiteralExprSyntax.self) else {
      throw diagnostic(
        at: argument.expression,
        id: "literal-required",
        message: "@Schema requires an inline string literal; runtime expressions are not supported."
      )
    }
    guard !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }) else {
      throw diagnostic(
        at: literal,
        id: "interpolation",
        message: "@Schema does not support string interpolation; use a complete JSON Schema literal."
      )
    }
    guard let source = literal.representedLiteralValue else {
      throw diagnostic(
        at: literal,
        id: "invalid-literal",
        message: "@Schema requires a valid Swift string literal."
      )
    }
    do {
      let generated = try SchemaGenerator().generate(source)
      let access = namespace.modifiers.first {
        $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.package)
      }.map { "\($0.name.text) " } ?? ""
      let body = generated.expression.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "    \($0)" }.joined(separator: "\n")
      return [
        DeclSyntax(stringLiteral: """
          \(access)static var schema: some JSONSchemaComponent<\(generated.outputType)> {
          \(body)
          }
          """)
      ]
    } catch let error as SchemaGenerationError {
      throw diagnostic(at: literal, id: "invalid-schema", message: error.description)
    }
  }

  private static func declaresSchema(_ declaration: DeclSyntax) -> Bool {
    if let name = declaration.asProtocol(NamedDeclSyntax.self)?.name.text,
      name == "schema" || name == "`schema`"
    {
      return true
    }
    if let variable = declaration.as(VariableDeclSyntax.self) {
      return variable.bindings.contains {
        $0.pattern.tokens(viewMode: .sourceAccurate).contains {
          $0.tokenKind == .identifier("schema") || $0.text == "`schema`"
        }
      }
    }
    if let cases = declaration.as(EnumCaseDeclSyntax.self) {
      return cases.elements.contains { $0.name.text == "schema" || $0.name.text == "`schema`" }
    }
    return false
  }

  private static func diagnostic(
    at node: some SyntaxProtocol,
    id: String,
    message: String
  ) -> DiagnosticsError {
    DiagnosticsError(diagnostics: [
      Diagnostic(node: node, message: SchemaDiagnostic(id: id, message: message))
    ])
  }
}

private struct SchemaDiagnostic: DiagnosticMessage {
  let id: String
  let message: String

  var diagnosticID: MessageID { MessageID(domain: "JSONSchemaCodegen", id: id) }
  var severity: DiagnosticSeverity { .error }
}
