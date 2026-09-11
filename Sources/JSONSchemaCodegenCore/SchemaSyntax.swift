import Foundation
import SwiftBasicFormat
import SwiftParserDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder

struct SchemaFragment {
  let expression: ExprSyntax
  let outputType: SchemaOutput
}

package struct GeneratedSchemaSyntax: Sendable {
  package let expression: ExprSyntax
  package let outputType: TypeSyntax
  package let declarations: [DeclSyntax]

  func serialized() -> GeneratedSchema {
    GeneratedSchema(
      expression: expression.trimmedDescription,
      outputType: outputType.trimmedDescription,
      declarations: declarations.map(\.trimmedDescription)
    )
  }
}

extension SchemaOutput {
  var syntax: TypeSyntax {
    switch self {
    case .named(let name):
      return TypeSyntax(IdentifierTypeSyntax(name: .identifier(name)))
    case .array(let item):
      return TypeSyntax(ArrayTypeSyntax(element: item.syntax))
    case .optional(let wrapped):
      return TypeSyntax(OptionalTypeSyntax(wrappedType: wrapped.syntax))
    case .tuple(let fields):
      return TypeSyntax(
        TupleTypeSyntax(
          elements: TupleTypeElementListSyntax {
            for (index, field) in fields.enumerated() {
              TupleTypeElementSyntax(
                firstName: SchemaSyntax.label(field.name),
                colon: .colonToken(),
                type: field.type.syntax,
                trailingComma: index < fields.count - 1 ? .commaToken() : nil
              )
            }
          }))
    }
  }
}

/// Builds syntax only; schema validation, reference resolution and shape decisions live elsewhere.
enum SchemaSyntax {
  static func stringLiteral(_ value: String) -> ExprSyntax {
    // SwiftSyntax's automatic delimiter detection iterates Characters, missing
    // quotes/backslashes joined to combining marks. Select a safe raw delimiter
    // by scalar; StringLiteralExprSyntax still handles control-character escapes.
    var needsDelimiter = false
    var followingEscape = false
    var pounds = 0
    var maximumPounds = 0
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"", "\\":
        needsDelimiter = true
        followingEscape = true
        pounds = 0
      case "#" where followingEscape:
        pounds += 1
        maximumPounds = max(maximumPounds, pounds)
      default:
        followingEscape = false
      }
    }
    let delimiter: TokenSyntax? =
      needsDelimiter
      ? .rawStringPoundDelimiter(String(repeating: "#", count: maximumPounds + 1)) : nil
    return ExprSyntax(
      StringLiteralExprSyntax(
        openDelimiter: delimiter, content: value, closeDelimiter: delimiter
      ))
  }

  static func reference(_ name: String) -> ExprSyntax {
    ExprSyntax(DeclReferenceExprSyntax(baseName: .identifier(name)))
  }

  static func label(_ name: String) -> TokenSyntax {
    .identifier("`\(name)`")
  }

  static func member(_ name: String) -> ExprSyntax {
    member(nil, name)
  }

  static func member(_ base: ExprSyntax?, _ name: String) -> ExprSyntax {
    ExprSyntax(
      MemberAccessExprSyntax(
        base: base,
        declName: DeclReferenceExprSyntax(
          baseName: .identifier(name)
        )))
  }

  static func argument(_ value: ExprSyntax, label: String? = nil) -> LabeledExprSyntax {
    LabeledExprSyntax(
      label: label.map { .identifier($0) },
      colon: label == nil ? nil : .colonToken(),
      expression: value
    )
  }

  static func call(
    _ callee: ExprSyntax,
    _ arguments: [LabeledExprSyntax] = [],
    body: [ExprSyntax]? = nil
  ) -> ExprSyntax {
    ExprSyntax(
      FunctionCallExprSyntax(
        calledExpression: callee,
        leftParen: body == nil || !arguments.isEmpty ? .leftParenToken() : nil,
        arguments: LabeledExprListSyntax(
          arguments.enumerated().map { index, argument in
            argument.with(\.trailingComma, index < arguments.count - 1 ? .commaToken() : nil)
          }),
        rightParen: body == nil || !arguments.isEmpty ? .rightParenToken() : nil,
        trailingClosure: body.map { expressions in
          ClosureExprSyntax(
            statements: CodeBlockItemListSyntax(
              expressions.map { CodeBlockItemSyntax(leadingTrivia: .newline, item: .expr($0)) }
            ))
        }
      ))
  }

  static func modifier(
    _ base: ExprSyntax, _ name: String,
    _ arguments: [LabeledExprSyntax] = [],
    closure: ClosureExprSyntax? = nil
  ) -> ExprSyntax {
    let callee = member(base, name).cast(MemberAccessExprSyntax.self)
      .with(\.period, .periodToken(leadingTrivia: .newline))
    var result = call(ExprSyntax(callee), arguments).cast(FunctionCallExprSyntax.self)
    if let closure {
      result.leftParen = nil
      result.rightParen = nil
      result.trailingClosure = closure
    }
    return ExprSyntax(result)
  }

  static func array(_ values: [ExprSyntax], multiline: Bool = false) -> ExprSyntax {
    ExprSyntax(
      ArrayExprSyntax(
        elements: ArrayElementListSyntax(
          values.enumerated().map { index, value in
            ArrayElementSyntax(
              leadingTrivia: multiline ? .newline : [],
              expression: value,
              trailingComma: index < values.count - 1 ? .commaToken() : nil
            )
          }),
        rightSquare: .rightSquareToken(leadingTrivia: multiline ? .newline : [])
      ))
  }

  static func dictionary(_ entries: [(ExprSyntax, ExprSyntax)]) -> ExprSyntax {
    ExprSyntax(
      DictionaryExprSyntax(
        content: entries.isEmpty
          ? .colon(.colonToken())
          : .elements(
            DictionaryElementListSyntax(
              entries.enumerated().map { index, entry in
                DictionaryElementSyntax(
                  key: entry.0, value: entry.1,
                  trailingComma: index < entries.count - 1 ? .commaToken() : nil
                )
              })
          )
      ))
  }

  static func metatype(_ type: TypeSyntax) -> ExprSyntax {
    member(ExprSyntax(TypeExprSyntax(type: type)), "self")
  }

  static func genericArgument(_ type: TypeSyntax) -> GenericArgumentSyntax {
    #if canImport(SwiftSyntax603)
      GenericArgumentSyntax(argument: .type(type))
    #else
      GenericArgumentSyntax(argument: type)
    #endif
  }

  static func unionDeclaration(_ name: String, outputs: [SchemaOutput]) -> DeclSyntax {
    DeclSyntax(
      EnumDeclSyntax(
        modifiers: [DeclModifierSyntax(name: .keyword(.public))],
        name: .identifier(name),
        inheritanceClause: InheritanceClauseSyntax(inheritedTypes: [
          InheritedTypeSyntax(type: IdentifierTypeSyntax(name: "Sendable"))
        ]),
        memberBlock: MemberBlockSyntax(
          members: MemberBlockItemListSyntax {
            for (index, output) in outputs.enumerated() {
              MemberBlockItemSyntax(
                decl: EnumCaseDeclSyntax(elements: [
                  EnumCaseElementSyntax(
                    name: .identifier("option\(index + 1)"),
                    parameterClause: EnumCaseParameterClauseSyntax(parameters: [
                      EnumCaseParameterSyntax(type: output.syntax)
                    ])
                  )
                ]))
            }
          })
      ))
  }

  static func unionMap(
    _ expression: ExprSyntax, input: TypeSyntax, output: TypeSyntax, index: Int
  ) -> ExprSyntax {
    let value = call(
      member(ExprSyntax(TypeExprSyntax(type: output)), "option\(index + 1)"),
      [
        argument(reference("value"))
      ])
    let closure = ClosureExprSyntax(
      signature: ClosureSignatureSyntax(
        attributes: [
          AttributeListSyntax.Element.attribute(
            AttributeSyntax(attributeName: IdentifierTypeSyntax(name: "Sendable")))
        ],
        parameterClause: .parameterClause(
          ClosureParameterClauseSyntax(parameters: [
            ClosureParameterSyntax(firstName: "value", colon: .colonToken(), type: input)
          ])),
        returnClause: ReturnClauseSyntax(type: output),
        inKeyword: .keyword(.in)
      ),
      statements: [CodeBlockItemSyntax(leadingTrivia: .newline, item: .expr(value))]
    )
    return modifier(expression, "map", closure: closure)
  }

  static func tupleMap(_ expression: ExprSyntax, fields: [SchemaOutput.Field]) -> ExprSyntax {
    let tuple = TupleExprSyntax(
      elements: LabeledExprListSyntax(
        fields.enumerated().map { index, field in
          LabeledExprSyntax(
            label: field.name == "inout" ? label(field.name) : .identifier(field.name),
            colon: .colonToken(),
            expression: member(reference("$0"), String(index)),
            trailingComma: index < fields.count - 1 ? .commaToken() : nil
          )
        }
      ))
    return modifier(
      expression, "map",
      closure: ClosureExprSyntax(statements: [
        CodeBlockItemSyntax(leadingTrivia: .newline, item: .expr(ExprSyntax(tuple)))
      ]))
  }

  static func booleanArray(_ array: ExprSyntax, flag: Bool) -> ExprSyntax {
    // Upstream does not copy boolean items. The explicit return type is also needed
    // when this immediately-invoked closure is nested in another builder.
    let variable = VariableDeclSyntax(
      .var, name: PatternSyntax(IdentifierPatternSyntax(identifier: "schema")),
      initializer: InitializerClauseSyntax(value: array)
    )
    let assignment: ExprSyntax = "schema.schemaValue[\"items\"] = .boolean(\(literal: flag))"
    let closure = ClosureExprSyntax(
      signature: ClosureSignatureSyntax(
        parameterClause: .parameterClause(ClosureParameterClauseSyntax(parameters: [])),
        returnClause: ReturnClauseSyntax(
          type: TypeSyntax("JSONArray<JSONComponents.PassthroughComponent<JSONBooleanSchema>>")
        ),
        inKeyword: .keyword(.in)
      ),
      statements: [
        CodeBlockItemSyntax(leadingTrivia: .newline, item: .decl(DeclSyntax(variable))),
        CodeBlockItemSyntax(leadingTrivia: .newline, item: .expr(assignment)),
        CodeBlockItemSyntax(
          leadingTrivia: .newline,
          item: .stmt(
            StmtSyntax(
              ReturnStmtSyntax(expression: reference("schema"))
            ))),
      ]
    )
    return call(ExprSyntax(closure))
  }

  static var validationHelper: DeclSyntax {
    """
    private static func _schemaWithDefinition<Component: JSONSchemaComponent>(
      _ component: Component, _ value: SchemaValue
    ) -> JSONComponents.AnySchemaComponent<Component.Output> {
      var schema = component.eraseToAnySchemaComponent()
      schema.schemaValue = value
      return schema
    }
    """
  }

  static func finish(
    _ fragment: SchemaFragment, declarations: [DeclSyntax], at location: ResolvedSchema
  ) throws -> GeneratedSchemaSyntax {
    let generated = GeneratedSchemaSyntax(
      expression: formatted(fragment.expression),
      outputType: formatted(fragment.outputType.syntax),
      declarations: declarations.map { formatted($0) }
    )
    let schema = DeclSyntax(
      VariableDeclSyntax(
        modifiers: [DeclModifierSyntax(name: .keyword(.static))],
        bindingSpecifier: .keyword(.var),
        bindings: [
          PatternBindingSyntax(
            pattern: IdentifierPatternSyntax(identifier: "schema"),
            typeAnnotation: TypeAnnotationSyntax(
              type: SomeOrAnyTypeSyntax(
                someOrAnySpecifier: .keyword(.some),
                constraint: IdentifierTypeSyntax(
                  name: "JSONSchemaComponent",
                  genericArgumentClause: GenericArgumentClauseSyntax(arguments: [
                    genericArgument(generated.outputType)
                  ])
                )
              )),
            accessorBlock: AccessorBlockSyntax(
              accessors: .getter([
                CodeBlockItemSyntax(item: .expr(generated.expression))
              ]))
          )
        ]
      ))
    let namespace = EnumDeclSyntax(
      name: "_GeneratedSchema",
      memberBlock: MemberBlockSyntax(
        members: MemberBlockItemListSyntax(
          (generated.declarations + [schema]).map { MemberBlockItemSyntax(decl: $0) }
        ))
    )
    let file = SourceFileSyntax(statements: [
      CodeBlockItemSyntax(item: .decl(DeclSyntax(namespace)))
    ])
    try validate(file, pointer: location.location.pointer, documentURI: location.documentURI)
    return generated
  }

  /// One deterministic style: two spaces, multiline closures, one modifier per line.
  /// Explicit array/branch trivia is set at construction; no source-text rewriting.
  static func formatted<Node: SyntaxProtocol>(_ node: Node) -> Node {
    node.formatted(using: BasicFormat(indentationWidth: .spaces(2))).cast(Node.self)
  }

  static func validate(
    _ file: SourceFileSyntax, pointer: String = "", documentURI: URL? = nil
  ) throws {
    // Diagnose the actual nodes, including missing/unexpected syntax. Reprinting
    // and reparsing loses that information and exhausts debug parser stacks on
    // large schemas. Round trips and real compiler checks belong in the tests.
    guard file.hasError else { return }
    let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: file)
      .filter { $0.diagMessage.severity == .error }
    guard !diagnostics.isEmpty else { return }
    let converter = SourceLocationConverter(fileName: "<generated>", tree: file)
    let messages = diagnostics.map { diagnostic in
      let location = diagnostic.location(converter: converter)
      return "<generated>:\(location.line):\(location.column): error: \(diagnostic.message)"
    }
    throw SchemaGenerationError(
      pointer: pointer,
      message: "Invalid generated Swift:\n" + messages.joined(separator: "\n"),
      documentURI: documentURI
    )
  }
}
