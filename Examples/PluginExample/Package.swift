// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "PluginExample",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "PluginExample",
      dependencies: [
        .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
      ],
      resources: [.copy("Schemas")],
      plugins: [
        .plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")
      ]
    )
  ]
)
