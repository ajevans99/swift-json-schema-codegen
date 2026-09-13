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
    guard
      !lexicalContext.contains(where: { syntax in
        if let generic = syntax.asProtocol(WithGenericParametersSyntax.self) {
          return generic.genericParameterClause != nil || generic.genericWhereClause != nil
        }
        return syntax.as(ExtensionDeclSyntax.self)?.genericWhereClause != nil
      })
    else {
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
      let argument = arguments.first, argument.label == nil,
      arguments.dropFirst().allSatisfy({ $0.label != nil })
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
        message:
          "@Schema does not support string interpolation; use a complete JSON Schema literal."
      )
    }
    guard let source = literal.representedLiteralValue else {
      throw diagnostic(
        at: literal,
        id: "invalid-literal",
        message: "@Schema requires a valid Swift string literal."
      )
    }
    let options = try generationOptions(in: arguments)
    do {
      let generated = try SchemaGenerator(options: options).generateSyntax(
        source, namespaceName: namespace.name.text
      )
      var modifiers = DeclModifierListSyntax()
      if let access = namespace.modifiers.first(where: {
        $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.package)
      }) {
        modifiers.append(access.trimmed)
      }
      modifiers.append(DeclModifierSyntax(name: .keyword(.static)))
      let output = generated.outputType
      let expression = generated.expression
      #if canImport(SwiftSyntax603)
        let outputArgument = GenericArgumentSyntax(argument: .type(output))
      #else
        let outputArgument = GenericArgumentSyntax(argument: output)
      #endif
      return generated.declarations + [
        DeclSyntax(
          VariableDeclSyntax(
            modifiers: modifiers,
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
                        outputArgument
                      ])
                    )
                  )),
                accessorBlock: AccessorBlockSyntax(
                  accessors: .getter([
                    CodeBlockItemSyntax(item: .expr(expression))
                  ]))
              )
            ]
          ))
      ]
    } catch let error as SchemaGenerationError {
      throw diagnostic(at: literal, id: "invalid-schema", message: error.description)
    }
  }

  private static func generationOptions(
    in arguments: LabeledExprListSyntax
  ) throws -> SchemaGenerationOptions {
    var options = SchemaGenerationOptions()
    var seen: Set<String> = []
    for argument in arguments.dropFirst() {
      let label = argument.label!.text
      guard ["output", "recursiveObjects", "typeNames", "caseNames"].contains(label) else {
        throw diagnostic(
          at: argument, id: "unknown-option", message: "@Schema has no option '\(label)'."
        )
      }
      guard seen.insert(label).inserted else {
        throw diagnostic(
          at: argument, id: "duplicate-option",
          message: "@Schema option '\(label)' may only be supplied once."
        )
      }
      switch label {
      case "output":
        let value = try enumCase(
          argument.expression, type: "SchemaOutputStyle", cases: ["tuples", "models"]
        )
        options.output = SchemaOutputStyle(rawValue: value)!
      case "recursiveObjects":
        let value = try enumCase(
          argument.expression, type: "RecursiveObjectStrategy",
          cases: ["valueTypes", "immutableClasses"]
        )
        options.recursiveObjects = RecursiveObjectStrategy(rawValue: value)!
      case "typeNames":
        options.names.typeNames = try nameOverrides(argument.expression, label: label)
      case "caseNames":
        options.names.caseNames = try nameOverrides(argument.expression, label: label)
      default:
        break
      }
    }
    return options
  }

  private static func enumCase(
    _ expression: ExprSyntax, type: String, cases: [String]
  ) throws -> String {
    if let member = expression.as(MemberAccessExprSyntax.self),
      member.declName.argumentNames == nil,
      cases.contains(member.declName.baseName.text)
    {
      if member.base == nil { return member.declName.baseName.text }
      if let base = member.base, let qualification = qualifiedName(base),
        qualification == [type]
          || qualification == ["JSONSchemaCodegen", type]
          || qualification == ["JSONSchemaCodegenCore", type]
          || qualification == ["JSONSchemaCodegenConfiguration", type]
      {
        return member.declName.baseName.text
      }
    }
    throw diagnostic(
      at: expression, id: "literal-enum-required",
      message:
        "@Schema requires a literal \(type) case: \(cases.map { "." + $0 }.joined(separator: " or "))."
    )
  }

  private static func qualifiedName(_ expression: ExprSyntax) -> [String]? {
    if let reference = expression.as(DeclReferenceExprSyntax.self),
      reference.argumentNames == nil
    {
      return [reference.baseName.text]
    }
    if let member = expression.as(MemberAccessExprSyntax.self),
      member.declName.argumentNames == nil, let base = member.base,
      let names = qualifiedName(base)
    {
      return names + [member.declName.baseName.text]
    }
    return nil
  }

  private static func nameOverrides(
    _ expression: ExprSyntax, label: String
  ) throws -> [String: String] {
    guard let dictionary = expression.as(DictionaryExprSyntax.self) else {
      throw diagnostic(
        at: expression, id: "literal-dictionary-required",
        message: "@Schema '\(label)' requires a literal dictionary of string selectors and names."
      )
    }
    guard case .elements(let elements) = dictionary.content else { return [:] }
    var names: [String: String] = [:]
    for element in elements {
      let selector = try overrideString(element.key, label: label)
      let name = try overrideString(element.value, label: label)
      guard !selector.isEmpty else {
        throw diagnostic(
          at: element.key, id: "empty-selector",
          message: "@Schema '\(label)' selectors must not be empty; use '#' for the root."
        )
      }
      guard names[selector] == nil else {
        throw diagnostic(
          at: element.key, id: "duplicate-selector",
          message: "@Schema '\(label)' contains duplicate selector '\(selector)'."
        )
      }
      guard isSchemaOverrideIdentifier(name) else {
        throw diagnostic(
          at: element.value, id: "invalid-name",
          message:
            "@Schema '\(label)' override '\(name)' must be an unquoted ASCII Swift identifier."
        )
      }
      names[selector] = name
    }
    return names
  }

  private static func overrideString(_ expression: ExprSyntax, label: String) throws -> String {
    guard let literal = expression.as(StringLiteralExprSyntax.self),
      !literal.segments.contains(where: { $0.is(ExpressionSegmentSyntax.self) }),
      let value = literal.representedLiteralValue
    else {
      throw diagnostic(
        at: expression, id: "literal-override-required",
        message: "@Schema '\(label)' keys and values must be non-interpolated string literals."
      )
    }
    return value
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
