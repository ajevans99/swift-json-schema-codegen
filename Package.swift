// swift-tools-version: 6.1

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-json-schema-codegen",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
    .tvOS(.v17),
    .watchOS(.v10),
    .macCatalyst(.v17),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "JSONSchemaCodegen", targets: ["JSONSchemaCodegen"]),
    .library(name: "JSONSchemaCodegenCore", targets: ["JSONSchemaCodegenCore"]),
    .executable(name: "json-schema-codegen", targets: ["JSONSchemaCodegenCLI"]),
    .plugin(name: "JSONSchemaCodegenPlugin", targets: ["JSONSchemaCodegenPlugin"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ajevans99/swift-json-schema.git", from: "0.13.2"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.1"..<"700.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
  ],
  targets: [
    .target(
      name: "JSONSchemaCodegenCore",
      dependencies: [
        .product(name: "OrderedJSON", package: "swift-json-schema"),
        .product(name: "SwiftBasicFormat", package: "swift-syntax"),
        .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
      ]
    ),
    .macro(
      name: "JSONSchemaCodegenMacros",
      dependencies: [
        "JSONSchemaCodegenCore",
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "JSONSchemaCodegen",
      dependencies: [
        "JSONSchemaCodegenMacros",
        .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
      ]
    ),
    .executableTarget(
      name: "JSONSchemaCodegenCLI",
      dependencies: [
        "JSONSchemaCodegenCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .plugin(
      name: "JSONSchemaCodegenPlugin",
      capability: .buildTool(),
      dependencies: ["JSONSchemaCodegenCLI"]
    ),
    .testTarget(
      name: "JSONSchemaCodegenCoreTests",
      dependencies: [
        "JSONSchemaCodegenCore",
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]
    ),
    .testTarget(
      name: "JSONSchemaCodegenMacroTests",
      dependencies: [
        "JSONSchemaCodegenMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "JSONSchemaCodegenTests",
      dependencies: [
        "JSONSchemaCodegen",
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]
    ),
  ]
)
