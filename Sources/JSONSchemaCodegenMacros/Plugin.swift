import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct JSONSchemaCodegenPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [SchemaMacro.self]
}
