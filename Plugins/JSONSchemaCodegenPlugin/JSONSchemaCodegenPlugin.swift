import Foundation
import PackagePlugin

@main
struct JSONSchemaCodegenPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
    guard target is SourceModuleTarget else { return [] }
    let inputs = try schemaFiles(in: target.directoryURL)
    // Exclude this file in Package.swift to avoid SwiftPM's unhandled-file warning;
    // the plugin reads it explicitly, even when it is excluded from target sources.
    let config = target.directoryURL.appendingPathComponent("json-schema-codegen.json")
    let configurationFile = FileManager.default.fileExists(atPath: config.path) ? config : nil
    guard !inputs.isEmpty || configurationFile != nil else { return [] }

    let outputDirectory = context.pluginWorkDirectoryURL.appendingPathComponent(
      "GeneratedSchemas", isDirectory: true
    )
    if inputs.isEmpty, let configurationFile {
      let stamp = context.pluginWorkDirectoryURL.appendingPathComponent("configuration.validated")
      return [
        .buildCommand(
          displayName: "Validate JSON schema configuration for \(target.name)",
          executable: try context.tool(named: "JSONSchemaCodegenCLI").url,
          arguments: ["_validate-config", configurationFile.path, "--stamp", stamp.path],
          inputFiles: [configurationFile],
          outputFiles: [stamp]
        )
      ]
    }
    var names: [String: URL] = [:]
    let outputs = try inputs.map { input in
      let typeName: String
      do {
        typeName = try SchemaFileNaming.typeName(for: input)
      } catch {
        throw PluginError(message: "\(input.path): \(error)")
      }
      let outputName = SchemaFileNaming.outputName(for: typeName)
      let collisionKey = outputName.lowercased()
      if let previous = names[collisionKey] {
        throw PluginError(
          message:
            "\(input.path): Generated filename '\(outputName)' collides with \(previous.path). Rename one of the input files."
        )
      }
      names[collisionKey] = input
      return outputDirectory.appendingPathComponent(outputName)
    }

    var arguments = ["--output-directory", outputDirectory.path]
    var inputFiles = inputs
    if let configurationFile {
      arguments.append(contentsOf: ["--config", configurationFile.path])
      inputFiles.append(configurationFile)
    }
    arguments.append("--")
    arguments.append(contentsOf: inputs.map(\.path))

    return [
      .buildCommand(
        displayName: "Generate JSON schemas for \(target.name)",
        executable: try context.tool(named: "JSONSchemaCodegenCLI").url,
        arguments: arguments,
        inputFiles: inputFiles,
        outputFiles: outputs
      )
    ]
  }

  private func schemaFiles(in directory: URL) throws -> [URL] {
    var discoveryError: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles],
        errorHandler: { _, error in
          discoveryError = error
          return false
        }
      )
    else {
      throw PluginError(message: "Unable to enumerate schema files in \(directory.path).")
    }
    var inputs: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".schema.json") {
      if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
        inputs.append(url.standardizedFileURL)
      }
    }
    if let discoveryError { throw discoveryError }
    return inputs.sorted { $0.path < $1.path }
  }
}

private struct PluginError: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}
