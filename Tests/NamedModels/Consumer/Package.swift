// swift-tools-version: 6.1
import Foundation
import PackageDescription

guard let root = ProcessInfo.processInfo.environment["NAMED_MODELS_REPOSITORY"] else {
  fatalError("Run this consumer through Tests/NamedModels/smoke.sh.")
}
let runtime = ProcessInfo.processInfo.environment["JSON_SCHEMA_RUNTIME_PATH"]
let package = Package(
  name: "NamedModelConsumer",
  platforms: [.macOS(.v14)],
  dependencies: [
    runtime.map { .package(name: "swift-json-schema", path: $0) } ?? .package(path: root)
  ],
  targets: [
    .target(
      name: "GeneratedModels",
      dependencies: [
        runtime == nil
          ? .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
          : .product(name: "JSONSchemaBuilder", package: "swift-json-schema")
      ]),
    .executableTarget(name: "NamedModelConsumer", dependencies: ["GeneratedModels"]),
  ]
)
