import SwiftSyntax
import SwiftSyntaxBuilder

extension SchemaModelSyntax {
  static func stringEnumMap(_ expression: ExprSyntax, output: SchemaOutput) -> ExprSyntax {
    SchemaSyntax.modifier(
      expression, "compactMap",
      closure: ClosureExprSyntax(
        signature: ClosureSignatureSyntax(
          parameterClause: .parameterClause(
            ClosureParameterClauseSyntax(parameters: [
              ClosureParameterSyntax(firstName: .identifier(parsedValueName))
            ])),
          returnClause: ReturnClauseSyntax(type: SchemaOutput.optional(output).syntax),
          inKeyword: .keyword(.in)),
        statements: [
          CodeBlockItemSyntax(
            item: .expr(
              SchemaSyntax.call(
                ExprSyntax(TypeExprSyntax(type: output.syntax)),
                [SchemaSyntax.argument(SchemaSyntax.reference(parsedValueName), label: "rawValue")]
              )))
        ]))
  }

  static func stringEnumDeclaration(
    name: String, values: [SchemaModelGraph.StringCase], cases: [String: String]
  ) -> DeclSyntax {
    let rawValue = VariableDeclSyntax(
      modifiers: [DeclModifierSyntax(name: .keyword(.public))],
      bindingSpecifier: .keyword(.var),
      bindings: [
        PatternBindingSyntax(
          pattern: IdentifierPatternSyntax(identifier: "rawValue"),
          typeAnnotation: TypeAnnotationSyntax(type: TypeSyntax("Swift.String")),
          accessorBlock: AccessorBlockSyntax(
            accessors: .getter([
              CodeBlockItemSyntax(
                item: .expr(
                  ExprSyntax(
                    SwitchExprSyntax(
                      subject: SchemaSyntax.reference("self"),
                      cases: SwitchCaseListSyntax(
                        values.map { value in
                          .switchCase(
                            SwitchCaseSyntax(
                              label: .case(
                                SwitchCaseLabelSyntax(caseItems: [
                                  SwitchCaseItemSyntax(
                                    pattern: ExpressionPatternSyntax(
                                      expression: SchemaSyntax.member("`\(cases[value.id]!)`")))
                                ])),
                              statements: [
                                CodeBlockItemSyntax(
                                  item: .expr(SchemaSyntax.stringLiteral(value.rawValue)))
                              ]))
                        })))))
            ])))
      ])
    let initializer = InitializerDeclSyntax(
      modifiers: [DeclModifierSyntax(name: .keyword(.public))],
      optionalMark: .postfixQuestionMarkToken(),
      signature: FunctionSignatureSyntax(
        parameterClause: FunctionParameterClauseSyntax(parameters: [
          FunctionParameterSyntax(firstName: "rawValue", type: TypeSyntax("Swift.String"))
        ])),
      body: CodeBlockSyntax(
        statements: CodeBlockItemListSyntax(
          values.map { value in
            let condition = SchemaSyntax.call(
              SchemaSyntax.member(
                SchemaSyntax.member(SchemaSyntax.reference("rawValue"), "unicodeScalars"),
                "elementsEqual"),
              [
                SchemaSyntax.argument(
                  SchemaSyntax.member(SchemaSyntax.stringLiteral(value.rawValue), "unicodeScalars"))
              ])
            return CodeBlockItemSyntax(
              item: .expr(
                ExprSyntax(
                  IfExprSyntax(
                    conditions: [ConditionElementSyntax(condition: .expression(condition))],
                    body: CodeBlockSyntax(statements: [
                      CodeBlockItemSyntax(
                        item: .expr(ExprSyntax("self = .\(raw: "`\(cases[value.id]!)`")"))),
                      CodeBlockItemSyntax(item: .stmt(StmtSyntax(ReturnStmtSyntax()))),
                    ])))))
          } + [CodeBlockItemSyntax(item: .stmt(StmtSyntax("return nil")))])))
    // RawRepresentable supplies raw-value-based equality/hash defaults even for
    // payload-free enums. Override both so canonical equivalents stay distinct.
    let equality: DeclSyntax = """
      public static func == (lhs: Self, rhs: Self) -> Swift.Bool {
        lhs.rawValue.unicodeScalars.elementsEqual(rhs.rawValue.unicodeScalars)
      }
      """
    let hash: DeclSyntax = """
      public func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(Swift.Array(rawValue.unicodeScalars))
      }
      """
    return DeclSyntax(
      EnumDeclSyntax(
        modifiers: [DeclModifierSyntax(name: .keyword(.public))],
        name: SchemaSyntax.label(name),
        inheritanceClause: InheritanceClauseSyntax(inheritedTypes: [
          InheritedTypeSyntax(
            type: TypeSyntax("Swift.RawRepresentable"), trailingComma: .commaToken()),
          InheritedTypeSyntax(type: TypeSyntax("Swift.Sendable"), trailingComma: .commaToken()),
          InheritedTypeSyntax(type: TypeSyntax("Swift.Hashable")),
        ]),
        memberBlock: MemberBlockSyntax(
          members: MemberBlockItemListSyntax(
            values.map { value in
              MemberBlockItemSyntax(
                decl: EnumCaseDeclSyntax(elements: [
                  EnumCaseElementSyntax(name: SchemaSyntax.label(cases[value.id]!))
                ]))
            } + [
              MemberBlockItemSyntax(decl: rawValue), MemberBlockItemSyntax(decl: initializer),
              MemberBlockItemSyntax(decl: equality), MemberBlockItemSyntax(decl: hash),
            ]))))
  }
}
