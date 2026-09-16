import SwiftSyntax
import SwiftSyntaxBuilder

enum SchemaParserFactorySyntax {
  static func declaration(_ name: String, fragment: SchemaFragment) -> DeclSyntax {
    DeclSyntax(
      FunctionDeclSyntax(
        modifiers: [
          DeclModifierSyntax(name: .keyword(.private)),
          DeclModifierSyntax(name: .keyword(.static)),
        ],
        name: .identifier(name),
        signature: FunctionSignatureSyntax(
          parameterClause: FunctionParameterClauseSyntax(parameters: []),
          returnClause: ReturnClauseSyntax(
            type: SomeOrAnyTypeSyntax(
              someOrAnySpecifier: .keyword(.some),
              constraint: IdentifierTypeSyntax(
                name: "JSONSchemaComponent",
                genericArgumentClause: GenericArgumentClauseSyntax(arguments: [
                  SchemaSyntax.genericArgument(fragment.outputType.syntax)
                ]))))),
        body: CodeBlockSyntax(statements: [
          CodeBlockItemSyntax(item: .expr(fragment.expression))
        ])))
  }
}
