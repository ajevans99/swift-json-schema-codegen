import SwiftSyntax
import SwiftSyntaxBuilder

extension SchemaSyntax {
  static func modelRecursiveReference(_ name: String, uriName: String? = nil) -> ExprSyntax {
    modifier(
      call(
        ExprSyntax(
          GenericSpecializationExprSyntax(
            expression: reference("JSONReference"),
            genericArgumentClause: GenericArgumentClauseSyntax(arguments: [
              genericArgument(SchemaOutput.named(SchemaModelNames.helperPrefix + name).syntax)
            ]))),
        [argument(stringLiteral("#/$defs/__codegen_" + (uriName ?? name)), label: "uri")]),
      "map",
      closure: ClosureExprSyntax(statements: [
        CodeBlockItemSyntax(item: .expr(member(reference("$0"), "value")))
      ]))
  }

  static func modelRecursiveDeclaration(_ name: String, output: SchemaOutput) -> DeclSyntax {
    """
    private struct \(raw: SchemaModelNames.helperPrefix + name): Schemable, Sendable {
      let value: \(output.syntax)
      static var schema: some JSONSchemaComponent<\(raw: SchemaModelNames.helperPrefix + name)> {
        \(raw: SchemaModelNames.helperPrefix + "Make" + name)()
      }
    }
    """
  }

  static func modelRecursiveFactory(_ name: String, expression: ExprSyntax) -> DeclSyntax {
    let mapped = modifier(
      expression, "map",
      closure: ClosureExprSyntax(statements: [
        CodeBlockItemSyntax(
          item: .expr(
            call(
              reference(SchemaModelNames.helperPrefix + name),
              [argument(reference("$0"), label: "value")])))
      ]))
    return DeclSyntax(
      FunctionDeclSyntax(
        modifiers: [
          DeclModifierSyntax(name: .keyword(.private)),
          DeclModifierSyntax(name: .keyword(.static)),
        ],
        name: .identifier(SchemaModelNames.helperPrefix + "Make" + name),
        signature: FunctionSignatureSyntax(
          parameterClause: FunctionParameterClauseSyntax(parameters: []),
          returnClause: ReturnClauseSyntax(
            type: TypeSyntax(
              "JSONComponents.AnySchemaComponent<\(raw: SchemaModelNames.helperPrefix + name)>"))),
        body: CodeBlockSyntax(statements: [
          CodeBlockItemSyntax(item: .expr(modifier(mapped, "eraseToAnySchemaComponent")))
        ])))
  }

  static func recursiveReference(_ name: String) -> ExprSyntax {
    call(
      ExprSyntax(
        GenericSpecializationExprSyntax(
          expression: reference("JSONReference"),
          genericArgumentClause: GenericArgumentClauseSyntax(arguments: [
            genericArgument(SchemaOutput.named(name).syntax)
          ])
        )),
      [argument(stringLiteral("#/$defs/__codegen_" + name), label: "uri")]
    )
  }

  static func recursiveDeclaration(_ name: String, output: SchemaOutput) -> DeclSyntax {
    DeclSyntax(
      EnumDeclSyntax(
        modifiers: [
          DeclModifierSyntax(name: .keyword(.public)),
          DeclModifierSyntax(name: .keyword(.indirect)),
        ],
        name: .identifier(name),
        inheritanceClause: InheritanceClauseSyntax(inheritedTypes: [
          InheritedTypeSyntax(
            type: IdentifierTypeSyntax(name: "Schemable"), trailingComma: .commaToken()),
          InheritedTypeSyntax(type: IdentifierTypeSyntax(name: "Sendable")),
        ]),
        memberBlock: MemberBlockSyntax(members: [
          MemberBlockItemSyntax(
            decl: EnumCaseDeclSyntax(elements: [
              EnumCaseElementSyntax(
                name: "value",
                parameterClause: EnumCaseParameterClauseSyntax(parameters: [
                  EnumCaseParameterSyntax(type: output.syntax)
                ]))
            ])),
          MemberBlockItemSyntax(
            decl: DeclSyntax(
              """
              public static var schema: some JSONSchemaComponent<\(raw: name)> {
                \(raw: "_make" + name)()
              }
              """
            )),
        ])
      ))
  }

  static func recursiveFactory(_ name: String, expression: ExprSyntax) -> DeclSyntax {
    let mapped = modifier(
      expression, "map",
      closure: ClosureExprSyntax(statements: [
        CodeBlockItemSyntax(
          item: .expr(call(member(reference(name), "value"), [argument(reference("$0"))])))
      ])
    )
    return DeclSyntax(
      FunctionDeclSyntax(
        modifiers: [
          DeclModifierSyntax(name: .keyword(.private)),
          DeclModifierSyntax(name: .keyword(.static)),
        ],
        name: .identifier("_make" + name),
        signature: FunctionSignatureSyntax(
          parameterClause: FunctionParameterClauseSyntax(parameters: []),
          returnClause: ReturnClauseSyntax(
            type: TypeSyntax("JSONComponents.AnySchemaComponent<\(raw: name)>"))
        ),
        body: CodeBlockSyntax(statements: [
          CodeBlockItemSyntax(item: .expr(modifier(mapped, "eraseToAnySchemaComponent")))
        ])
      ))
  }
}
