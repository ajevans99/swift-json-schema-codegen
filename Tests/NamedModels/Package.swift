// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "NamedModelConsumers",
  platforms: [.macOS(.v14)],
  dependencies: [.package(name: "swift-json-schema-codegen", path: "../..")],
  targets: [
    .executableTarget(
      name: "GenerateNamedModels",
      dependencies: [
        .product(name: "JSONSchemaCodegenCore", package: "swift-json-schema-codegen")
      ])
  ]
)
