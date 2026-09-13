import Foundation
import JSONSchema
import JSONSchemaBuilder

struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

func check(_ condition: Bool, _ message: String) throws {
  guard condition else { throw CheckFailure(description: message) }
}

func rejects<Output>(
  _ schema: some JSONSchemaComponent<Output>, _ payload: String, _ message: String
) throws {
  do {
    _ = try schema.parseAndValidate(instance: payload)
  } catch let issue as ParseAndValidateIssue {
    switch issue {
    case .validationFailed, .parsingAndValidationFailed:
      return
    case .decodingFailed, .parsingFailed:
      throw CheckFailure(
        description: "\(message) failed without a schema validation failure: \(issue)")
    }
  }
  throw CheckFailure(description: "Expected rejection: \(message)")
}

func json(_ object: [String: Any]) throws -> String {
  String(
    decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
    as: UTF8.self)
}

guard CommandLine.arguments.count == 2 else {
  throw CheckFailure(description: "Usage: OpenAPIConsumer <theme.json>")
}
let themeSource = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
#if NAMED_MODELS
  let theme: ThemeSchema.Value = try ThemeSchema.schema.parseAndValidate(instance: themeSource)
#else
  let theme = try ThemeSchema.schema.parseAndValidate(instance: themeSource)
#endif
try check(theme.id == "theme_midnight", "allOf lost the base id field")
try check(theme.name == "Midnight", "allOf lost the base name field")
try check(theme.palette.accent == "#7f56d9", "allOf lost the palette fields")
try check(
  theme.body.family == "serif" && theme.body.size == 16, "Shared typography reference failed")
try check(
  theme.body.lineHeight == 1.5 && theme.caption == nil, "Optional property presence changed")

guard let object = try JSONSerialization.jsonObject(with: Data(themeSource.utf8)) as? [String: Any]
else {
  throw CheckFailure(description: "The theme fixture must contain a JSON object")
}
for field in ["id", "name", "palette", "body"] {
  var missing = object
  missing.removeValue(forKey: field)
  try rejects(ThemeSchema.schema, try json(missing), "allOf must require \(field)")
}
var invalidID = object
invalidID["id"] = "invalid"
try rejects(ThemeSchema.schema, try json(invalidID), "Base id pattern")
var invalidName = object
invalidName["name"] = ""
try rejects(ThemeSchema.schema, try json(invalidName), "Base name minLength")
var invalidTypography = object
invalidTypography["body"] = ["family": "serif", "size": 9]
try rejects(ThemeSchema.schema, try json(invalidTypography), "Referenced typography minimum")
var invalidPalette = object
invalidPalette["palette"] = ["background": "#101828", "foreground": "#f9fafb", "accent": "purple"]
try rejects(ThemeSchema.schema, try json(invalidPalette), "Referenced color pattern")

try check(
  FontFamilySchema.schema.parseAndValidate(instance: #""Inter""#) == "Inter",
  "First same-output anyOf branch"
)
try check(
  FontFamilySchema.schema.parseAndValidate(instance: #""serif""#) == "serif",
  "Second same-output anyOf branch"
)
try rejects(FontFamilySchema.schema, #""Comic Sans""#, "Neither font pattern accepts this family")

let readySource = #"{"status":"ready","theme":\#(themeSource)}"#
let ready = try ThemeResponseSchema.schema.parseAndValidate(instance: readySource)
#if NAMED_MODELS
  guard case .ready(let readyPayload) = ready else {
    throw CheckFailure(description: "Ready response did not choose the semantic ready case")
  }
#else
  guard case .option1(let readyPayload) = ready else {
    throw CheckFailure(description: "Ready response did not choose option1")
  }
#endif
try check(
  readyPayload.status == "ready" && readyPayload.theme.name == "Midnight", "Ready enum payload")
try check(readyPayload.theme.body.size == 16, "Nested allOf payload is not accessible")

// Both object parsers can extract their fields here. Only const validation can
// reject the first branch and choose the pending branch's typed payload.
let pendingSource = """
  {"status":"pending","theme":\(themeSource),"jobId":"job_42","retryAfter":5}
  """
let pending = try ThemeResponseSchema.schema.parseAndValidate(instance: pendingSource)
#if NAMED_MODELS
  guard case .pending(let pendingPayload) = pending else {
    throw CheckFailure(description: "Pending response did not choose the semantic pending case")
  }
#else
  guard case .option2(let pendingPayload) = pending else {
    throw CheckFailure(
      description: "Pending response chose the wrong branch; const tags must drive selection")
  }
#endif
try check(
  pendingPayload.jobId == "job_42" && pendingPayload.retryAfter == 5, "Pending enum payload")
try rejects(
  ThemeResponseSchema.schema,
  pendingSource.replacingOccurrences(of: #""pending""#, with: #""unknown""#),
  "Unknown status must match no oneOf branch"
)
try rejects(
  ThemeResponseSchema.schema,
  #"{"status":"pending","jobId":"job_42","retryAfter":0}"#,
  "Pending retry interval constraint"
)
try rejects(
  ThemeResponseSchema.schema, #"{"status":"ready"}"#,
  "Ready branch requires its theme payload"
)

// Supporting union declarations remain scoped to their own schema namespace.
let feed = try ThemeFeedSchema.schema.parseAndValidate(
  instance: "[\(readySource),\(pendingSource)]")
try check(feed.count == 2, "Theme feed count")
#if NAMED_MODELS
  guard case .pending(let feedPending) = feed[1] else {
    throw CheckFailure(description: "Named array union did not choose the pending case")
  }
#else
  guard case .option2(let feedPending) = feed[1] else {
    throw CheckFailure(description: "Nested array union did not choose the pending case")
  }
#endif
try check(feedPending.retryAfter == 5, "Array union payload")

print(
  "OpenAPI example passed: allOf required fields, shared refs, anyOf patterns, oneOf enum payloads")
