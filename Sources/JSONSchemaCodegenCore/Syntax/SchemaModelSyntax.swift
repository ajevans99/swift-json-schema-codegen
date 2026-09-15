import Foundation
import SwiftSyntax
import SwiftSyntaxBuilder

enum SchemaModelSyntax {
  static let parsedValueName = SchemaModelNames.helperPrefix + "ParsedValue"

  /// Lossless internal tokens are replaced structurally after graph-wide allocation.
  /// They are never public names and are not used as naming evidence.
  static func symbol(_ identity: String) -> String {
    SchemaModelNames.helperPrefix + "Model"
      + identity.utf8.map { String(format: "%02x", $0) }.joined()
  }

  static func map(_ expression: ExprSyntax, to output: SchemaOutput, value: ExprSyntax)
    -> ExprSyntax
  {
    SchemaSyntax.modifier(
      expression, "map",
      closure: ClosureExprSyntax(
        signature: ClosureSignatureSyntax(
          parameterClause: .parameterClause(
            ClosureParameterClauseSyntax(parameters: [
              ClosureParameterSyntax(firstName: .identifier(parsedValueName))
            ])),
          returnClause: ReturnClauseSyntax(type: output.syntax),
          inKeyword: .keyword(.in)),
        statements: [CodeBlockItemSyntax(item: .expr(value))]
      ))
  }

  static func objectMap(
    _ expression: ExprSyntax, output: SchemaOutput,
    fields: [SchemaModelGraph.Field], hasAdditional: Bool
  ) -> ExprSyntax {
    // JSONObject yields raw fields; typed extras wrap them as (fields, matches).
    // Construct models directly rather than adding intermediate labeled-tuple maps.
    let preservesUnknown = fields.contains(where: \.unmodeled)
    let count = fields.filter { $0.key != nil }.count
    let parsed = SchemaSyntax.reference(parsedValueName)
    let upstream = preservesUnknown ? SchemaSyntax.member(parsed, "0") : parsed
    let parameters = fields.enumerated().map { index, field in
      let value: ExprSyntax
      if field.unmodeled {
        value = SchemaSyntax.member(parsed, "1")
      } else if hasAdditional && field.key == nil {
        let matches = SchemaSyntax.member(SchemaSyntax.member(upstream, "1"), "matches")
        if preservesUnknown && count > 0 {
          let keys = SchemaSyntax.array(fields.compactMap(\.key).map(SchemaSyntax.stringLiteral))
          value = "\(matches).filter { !\(keys).contains($0.key) }"
        } else {
          value = matches
        }
      } else {
        let base =
          hasAdditional
          ? SchemaSyntax.member(upstream, "0")
          : upstream
        value = count == 1 ? base : SchemaSyntax.member(base, String(index))
      }
      return SchemaSyntax.argument(value, label: field.name == "inout" ? "`inout`" : field.name)
    }
    return map(
      expression, to: output,
      value: SchemaSyntax.call(ExprSyntax(TypeExprSyntax(type: output.syntax)), parameters))
  }

  static func unionMap(
    _ expression: ExprSyntax, output: SchemaOutput, branch: String, null: Bool
  ) -> ExprSyntax {
    let member = SchemaSyntax.member(
      ExprSyntax(TypeExprSyntax(type: output.syntax)), symbol(branch))
    return map(
      expression, to: output,
      value: null
        ? member
        : SchemaSyntax.call(
          member, [SchemaSyntax.argument(SchemaSyntax.reference(parsedValueName))]))
  }

  static func declarations(
    graph: SchemaModelGraph, names: [String: String], cases: [String: String],
    layout: SchemaModelLayout, includesRootAlias: Bool = true
  ) throws -> [DeclSyntax] {
    let rewriter = SchemaModelRewriter(names: names, cases: cases, references: [:])
    func type(_ output: SchemaOutput) throws -> TypeSyntax {
      let resolved = try graph.resolving(output)
      return rewriter.rewrite(resolved.syntax).cast(TypeSyntax.self)
    }
    var declarations: [DeclSyntax] = []
    for id in graph.definitions.keys.sorted(by: { names[$0]! < names[$1]! }) {
      let definition = graph.definitions[id]!
      let name = names[id]!
      switch definition.shape {
      case .object(let fields):
        var parameterNames = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.name) })
        if parameterNames["self"] != nil {
          let reserved = Set(fields.map(\.name))
          var name = "_self"
          var suffix = 2
          while reserved.contains(name) {
            name = "_self_\(suffix)"
            suffix += 1
          }
          parameterNames["self"] = name
        }
        var members: [MemberBlockItemSyntax] = []
        for field in fields {
          members.append(
            MemberBlockItemSyntax(
              decl: VariableDeclSyntax(
                modifiers: [DeclModifierSyntax(name: .keyword(.public))],
                bindingSpecifier: .keyword(.let),
                bindings: [
                  PatternBindingSyntax(
                    pattern: IdentifierPatternSyntax(identifier: SchemaSyntax.label(field.name)),
                    typeAnnotation: TypeAnnotationSyntax(type: try type(field.type)))
                ])))
        }
        let initializer = InitializerDeclSyntax(
          modifiers: [DeclModifierSyntax(name: .keyword(.public))],
          signature: FunctionSignatureSyntax(
            parameterClause: FunctionParameterClauseSyntax(
              parameters: FunctionParameterListSyntax(
                try fields.enumerated().map { index, field in
                  let defaultValue: InitializerClauseSyntax? =
                    field.unmodeled
                    ? InitializerClauseSyntax(value: SchemaSyntax.dictionary([]))
                    : field.absent ? InitializerClauseSyntax(value: NilLiteralExprSyntax()) : nil
                  return FunctionParameterSyntax(
                    firstName: SchemaSyntax.label(field.name),
                    secondName: field.name == parameterNames[field.name]
                      ? nil : .identifier(parameterNames[field.name]!),
                    type: try type(field.type),
                    defaultValue: defaultValue,
                    trailingComma: index < fields.count - 1 ? .commaToken() : nil)
                }))),
          body: CodeBlockSyntax(
            statements: CodeBlockItemListSyntax(
              fields.map { field in
                CodeBlockItemSyntax(
                  item: .expr(
                    ExprSyntax(
                      "self.\(raw: "`\(field.name)`") = \(raw: "`\(parameterNames[field.name]!)`")")
                  ))
              })))
        members.append(MemberBlockItemSyntax(decl: initializer))
        let inheritance = InheritanceClauseSyntax(inheritedTypes: [
          InheritedTypeSyntax(type: IdentifierTypeSyntax(name: "Sendable"))
        ])
        if layout.classes.contains(id) {
          declarations.append(
            DeclSyntax(
              ClassDeclSyntax(
                modifiers: [
                  DeclModifierSyntax(name: .keyword(.public)),
                  DeclModifierSyntax(name: .keyword(.final)),
                ],
                name: SchemaSyntax.label(name), inheritanceClause: inheritance,
                memberBlock: MemberBlockSyntax(members: MemberBlockItemListSyntax(members)))))
        } else {
          declarations.append(
            DeclSyntax(
              StructDeclSyntax(
                modifiers: [DeclModifierSyntax(name: .keyword(.public))],
                name: SchemaSyntax.label(name), inheritanceClause: inheritance,
                memberBlock: MemberBlockSyntax(members: MemberBlockItemListSyntax(members)))))
        }
      case .union(let branches):
        var modifiers = [DeclModifierSyntax(name: .keyword(.public))]
        if layout.indirectEnums.contains(id) {
          modifiers.append(DeclModifierSyntax(name: .keyword(.indirect)))
        }
        declarations.append(
          DeclSyntax(
            EnumDeclSyntax(
              modifiers: DeclModifierListSyntax(modifiers), name: SchemaSyntax.label(name),
              inheritanceClause: InheritanceClauseSyntax(inheritedTypes: [
                InheritedTypeSyntax(type: IdentifierTypeSyntax(name: "Sendable"))
              ]),
              memberBlock: MemberBlockSyntax(
                members: MemberBlockItemListSyntax(
                  try branches.map { branch in
                    MemberBlockItemSyntax(
                      decl: EnumCaseDeclSyntax(elements: [
                        EnumCaseElementSyntax(
                          name: SchemaSyntax.label(cases[branch.id]!),
                          parameterClause: try graph.resolving(branch.type) == .named("Void")
                            ? nil
                            : EnumCaseParameterClauseSyntax(parameters: [
                              EnumCaseParameterSyntax(type: try type(branch.type))
                            ]))
                      ]))
                  })))))
      case .stringEnum(let values):
        declarations.append(stringEnumDeclaration(name: name, values: values, cases: cases))
      }
    }
    if !includesRootAlias { return declarations }
    if case .model(let id) = try graph.resolving(graph.root), names[id] == "Value" {
      return declarations
    }
    declarations.insert(
      DeclSyntax("public typealias Value = \(try type(graph.root))"), at: 0)
    return declarations
  }
}

/// Replaces only compiler identifiers/types, never JSON keys or validation literals.
final class SchemaModelRewriter: SyntaxRewriter {
  private let symbols: [String: String]
  private let references: [String: TypeSyntax]

  init(names: [String: String], cases: [String: String], references: [String: TypeSyntax]) {
    symbols = Dictionary(
      uniqueKeysWithValues: (names.merging(cases) { first, _ in first }).map {
        (SchemaModelSyntax.symbol($0.key), "`\($0.value)`")
      })
    self.references = references
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ token: TokenSyntax) -> TokenSyntax {
    guard case .identifier(let text) = token.tokenKind, let replacement = symbols[text] else {
      return token
    }
    return token.with(\.tokenKind, .identifier(replacement))
  }

  override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
    if let reference = references[node.name.text] { return reference }
    return super.visit(node)
  }
}
