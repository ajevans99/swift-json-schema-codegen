// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "PluginExample",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "swift-json-schema-codegen", path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "PluginExample",
      dependencies: [
        .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
      ],
      exclude: ["json-schema-codegen.json"],
      resources: [.copy("Schemas"), .copy("Fixtures")],
      plugins: [
        .plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")
      ]
    )
  ]
)
