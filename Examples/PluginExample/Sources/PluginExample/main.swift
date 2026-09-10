import JSONSchemaCodegen

let theme = try ThemeSchema.schema.parseAndValidate(
  instance: #"{"name":"Midnight","dark":true}"#
)
let name: String = theme.name
let dark: Bool = theme.dark
precondition(name == "Midnight" && dark)

let score: Int = try ScoreSchema.schema.parseAndValidate(instance: "42")
precondition(score == 42)
precondition(
  !ThemeSchema.schema.definition().validate(["name": "", "dark": true]).isValid
)
precondition(!ScoreSchema.schema.definition().validate(101).isValid)
print("Plugin example passed: \(name), dark=\(dark), score=\(score)")
