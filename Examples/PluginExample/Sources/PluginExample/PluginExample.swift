import Foundation
import JSONSchemaCodegen

@main
enum PluginExample {
  static func main() throws {
    let theme: ThemeSchema.Value = try ThemeSchema.schema.parseAndValidate(
      instance: fixture("Valid/theme.json"))
    guard theme.name == "Midnight", theme.dark else {
      throw ExampleFailure("Theme fixture did not round-trip expected values.")
    }
    guard theme.mode == .dark else {
      throw ExampleFailure("Theme mode should resolve through the local anchor.")
    }
    guard theme.colors.background.base == "#101828",
      theme.colors.foreground.muted == "#98A2B3"
    else {
      throw ExampleFailure("Shared palette references were not lowered correctly.")
    }
    guard theme.typography.body.fontFamily == "Inter",
      theme.typography.heading.fontSize == 24
    else {
      throw ExampleFailure("Shared typography references did not infer the expected members.")
    }
    guard theme.spacing.unit == 4, theme.spacing.steps == [0, 1, 2, 4] else {
      throw ExampleFailure("Shared spacing scale did not validate as expected.")
    }

    let score: ScoreSchema.Value = try ScoreSchema.schema.parseAndValidate(
      instance: fixture("Valid/score.json"))
    guard score == 42 else {
      throw ExampleFailure("Score fixture should validate to 42.")
    }

    let settings: AppSettingsSchema.Value = try AppSettingsSchema.schema.parseAndValidate(
      instance: fixture("Valid/app-settings.json")
    )
    // Each generated namespace owns its enum; bridge through the public raw-value initializer.
    guard let preferredThemeMode = ThemeSchema.ThemeMode(rawValue: settings.preferredMode.rawValue),
      settings.themeName == theme.name, preferredThemeMode == theme.mode,
      settings.preferredMode.rawValue.unicodeScalars.map(\.value)
        == theme.mode.rawValue.unicodeScalars.map(\.value)
    else {
      throw ExampleFailure("Settings should reuse shared theme naming and mode definitions.")
    }
    guard settings.notifications.mentionsOnly, settings.layout.gutter == 24 else {
      throw ExampleFailure("Settings fixture did not preserve named model fields.")
    }
    guard settings.bodyStyle.lineHeight == 1.5, settings.spacing.steps == [0, 1, 2, 4] else {
      throw ExampleFailure("Settings should reuse shared typography and spacing resources.")
    }
    guard settings.scoreLimit == score, settings.recentAccentColors == ["#7C3AED", "#06B6D4"] else {
      throw ExampleFailure("Settings should reference the shared score and color tokens.")
    }

    try expectValidationFailure("theme bad hex", fixture("Invalid/theme-bad-hex.json")) {
      try ThemeSchema.schema.parseAndValidate(instance: $0)
    }
    try expectValidationFailure(
      "theme missing typography line height", fixture("Invalid/theme-missing-line-height.json")
    ) {
      try ThemeSchema.schema.parseAndValidate(instance: $0)
    }
    try expectValidationFailure(
      "settings score above maximum", fixture("Invalid/app-settings-score-too-high.json")
    ) {
      try AppSettingsSchema.schema.parseAndValidate(instance: $0)
    }
    try expectValidationFailure(
      "settings duplicate accent colors",
      fixture("Invalid/app-settings-duplicate-recent-accent-colors.json")
    ) {
      try AppSettingsSchema.schema.parseAndValidate(instance: $0)
    }

    print("Plugin example passed: \(theme.name), dark=\(theme.dark), score=\(score)")
    print(
      "Plugin shared refs passed: mode=\(settings.preferredMode.rawValue), body=\(settings.bodyStyle.fontFamily), accents=\(settings.recentAccentColors.count)"
    )
  }

  private static func fixture(_ relativePath: String) throws -> String {
    guard
      let url = Bundle.module.resourceURL?
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(relativePath)
    else {
      throw ExampleFailure("Bundle.module did not expose the Fixtures directory.")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private static func expectValidationFailure<Output>(
    _ label: String,
    _ instance: String,
    parseAndValidate: (String) throws -> Output
  ) throws {
    do {
      _ = try parseAndValidate(instance)
      throw ExampleFailure("\(label) unexpectedly succeeded.")
    } catch let issue as ParseAndValidateIssue {
      switch issue {
      case .validationFailed(let result), .parsingAndValidationFailed(_, let result):
        guard result.isValid == false else {
          throw ExampleFailure("\(label) should produce an invalid validation result.")
        }
      case .decodingFailed(let error):
        throw ExampleFailure("\(label) should fail validation, not JSON decoding: \(error)")
      case .parsingFailed:
        throw ExampleFailure("\(label) should fail validation with a schema result.")
      }
    }
  }
}

private struct ExampleFailure: Error, CustomStringConvertible {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var description: String { message }
}
