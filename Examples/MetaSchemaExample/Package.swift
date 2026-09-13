// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "MetaSchemaExample",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "MetaSchemaExample",
      dependencies: [
        .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
      ],
      exclude: ["json-schema-codegen.json"],
      resources: [.copy("Schemas")],
      plugins: [
        .plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")
      ]
    )
  ]
)
