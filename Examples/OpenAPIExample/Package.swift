// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "OpenAPIExample",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "openapi-generate", targets: ["OpenAPIGenerate"])
  ],
  dependencies: [
    .package(name: "swift-json-schema-codegen", path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "OpenAPIGenerate",
      dependencies: [
        .product(name: "JSONSchemaCodegenCore", package: "swift-json-schema-codegen")
      ]
    )
  ]
)
