#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/Tests/Support/runtime.sh"
mkdir -p "$root/.build"
work="$root/.build/named-entry-points-$$"
mkdir "$work"
trap 'rm -rf -- "$work"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  local expected="$1"
  shift
  if "$@" >"$work/stdout" 2>"$work/stderr"; then
    fail "Expected failure: $*"
  fi
  [[ ! -s "$work/stdout" ]] || fail "Failure wrote to stdout"
  grep -Fq -- "$expected" "$work/stderr" ||
    { cat "$work/stderr" >&2; fail "Missing diagnostic: $expected"; }
}

if [[ -n "${CODEGEN_BIN:-}" ]]; then
  cli="$CODEGEN_BIN"
else
  swift build --package-path "$root" --product json-schema-codegen >"$work/build.log" 2>&1 ||
    { cat "$work/build.log" >&2; fail "CLI build"; }
  cli="$(swift build --package-path "$root" --show-bin-path)/json-schema-codegen"
fi
"$cli" --help >"$work/help"
for option in --output-style --recursive-objects --config; do
  grep -Fq -- "$option" "$work/help" || fail "Missing help option $option"
done
grep -Fq 'value-types' "$work/help"
grep -Fq 'immutable-classes' "$work/help"
mkdir "$work/inputs"
cat >"$work/inputs/theme.schema.json" <<'JSON'
{"type":"object","properties":{"payload":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},"choice":{"oneOf":[{"type":"string"},{"type":"integer"}]}},"required":["payload","choice"]}
JSON
printf '%s\n' '{"type":"string"}' >"$work/inputs/other.schema.json"

expect_failure "is invalid for" "$cli" --output-directory "$work/out" --output-style named \
  "$work/inputs/theme.schema.json"
expect_failure "is invalid for" "$cli" --output-directory "$work/out" --recursive-objects classes \
  "$work/inputs/theme.schema.json"

config="$work/json-schema-codegen.json"
config_failure() {
  local json="$1" pointer="$2" diagnostic="$3"
  printf '%s\n' "$json" >"$config"
  expect_failure "$diagnostic" "$cli" --output-directory "$work/out" --config "$config" \
    "$work/inputs/theme.schema.json"
  grep -Fq "$config: #$pointer:" "$work/stderr" ||
    { cat "$work/stderr" >&2; fail "Missing configuration location $pointer"; }
  [[ ! -e "$work/out" ]] || fail "Invalid configuration created output"
}
config_failure '{"version":2}' /version 'Unsupported configuration version'
config_failure '{}' /version 'Missing required configuration key'
config_failure '{"version":"1"}' /version 'Expected to decode Int'
config_failure '{"version":true}' /version 'Expected to decode Int'
config_failure '{"version":1,"outpt":"models"}' /outpt 'Unknown configuration key'
config_failure '{"version":1,"output":null}' /output 'null'
config_failure '{"version":1,"output":"named"}' /output 'SchemaOutputStyle'
config_failure '{"version":1,"recursiveObjects":"immutable-classes"}' /recursiveObjects 'RecursiveObjectStrategy'
config_failure '{"version":1,"typeNames":[]}' /typeNames 'Dictionary'
config_failure '{"version":1,"output":"models","typeNames":{"#":42}}' '/typeNames/#' 'String'
config_failure '{"version":1,"output":"models","typeNames":{"#":"Bad.Name"}}' '/typeNames/#' 'ASCII Swift identifier'
config_failure '{"version":1,"output":"models","typeNames":{"":"Name"}}' '/typeNames/' 'must not be empty'
config_failure '{"version":1,"output":"models","typeNames":{"#/properties/a~2":"Name"}}' '/typeNames/#~1properties~1a~02' "invalid JSON Pointer '~' escape"
config_failure '{"version":1,"output":"models","typeNames":{"#/%QQ":"Name"}}' '/typeNames/#~1%QQ' 'valid JSON Pointer fragment'
config_failure '{"version":1,"recursiveObjects":"immutableClasses"}' /recursiveObjects 'requires named-model output'
config_failure '{"version":1,"typeNames":{"#":"Name"}}' /typeNames 'requires named-model output'

# Configuration diagnostics precede schema reads, and never partially rewrite a batch.
printf '%s\n' '{"version":2}' >"$config"
expect_failure 'Unsupported configuration version' "$cli" --config "$config" \
  --output-directory "$work/out" "$work/inputs/missing.schema.json"
printf '%s\n' '{"version":1,"output":"models","typeNames":{"#/properties/payload":"Message"}}' >"$config"
expect_failure 'Fragment-only selector' "$cli" --output-directory "$work/out" --config "$config" \
  "$work/inputs/theme.schema.json" "$work/inputs/other.schema.json"
[[ ! -e "$work/out" ]] || fail "Ambiguous configuration created output"

# Omitted flags preserve configuration; explicit flags win over configuration.
printf '%s\n' '{"version":1,"output":"models"}' >"$config"
"$cli" --config "$config" --output-directory "$work/models" "$work/inputs/theme.schema.json"
grep -Eq 'struct `?Value`?' "$work/models/ThemeSchema.generated.swift"
"$cli" --config "$config" --output-style tuples --output-directory "$work/tuples" \
  "$work/inputs/theme.schema.json"
if grep -Eq 'struct `?Value`?' "$work/tuples/ThemeSchema.generated.swift"; then
  fail "Explicit tuples flag did not override models configuration"
fi
printf '%s\n' '{"version":1,"output":"tuples"}' >"$config"
"$cli" --config "$config" --output-style models --output-directory "$work/explicit-models" \
  "$work/inputs/theme.schema.json"
cmp "$work/models/ThemeSchema.generated.swift" "$work/explicit-models/ThemeSchema.generated.swift"

# A target with configuration but no schemas still gets strict config validation.
printf '%s\n' '{"version":2}' >"$config"
expect_failure 'Unsupported configuration version' "$cli" _validate-config "$config" \
  --stamp "$work/stamp"
[[ ! -e "$work/stamp" ]] || fail "Invalid configuration wrote validation stamp"
printf '%s\n' '{"version":1,"output":"models"}' >"$config"
"$cli" _validate-config "$config" --stamp "$work/stamp"
[[ -f "$work/stamp" ]] || fail "Config-only validation did not run"

# Config-relative, document-qualified selectors remain independent of the invocation directory.
cat >"$config" <<'JSON'
{"version":1,"output":"models","typeNames":{"inputs/theme.schema.json#/properties/payload":"Message","inputs/theme.schema.json#/properties/choice":"Choice"},"caseNames":{"inputs/theme.schema.json#/properties/choice/oneOf/0":"text"}}
JSON
"$cli" --config "$config" --output-directory "$work/named" \
  "$work/inputs/theme.schema.json"
cp "$config" "$work/batch-config.json"
grep -Eq 'struct `?Message`?' "$work/named/ThemeSchema.generated.swift"
grep -Eq 'enum `?Choice`?' "$work/named/ThemeSchema.generated.swift"
grep -Eq 'case `?text`?\(' "$work/named/ThemeSchema.generated.swift"

# A semantic override error includes both the configuration location and schema error.
printf '%s\n' '{"version":1,"output":"models","typeNames":{"#/properties/missing":"Missing"}}' >"$config"
expect_failure 'override' "$cli" --config "$config" --output-directory "$work/out" \
  "$work/inputs/theme.schema.json"
grep -Fq "$config: #" "$work/stderr"
[[ ! -e "$work/out" ]] || fail "Unresolved override created output"

# Compile an actual external consumer of the CLI-selected public model names.
consumer="$work/Consumer"
mkdir -p "$consumer/Sources/Consumer" "$consumer/Sources/NoSchemas"
cp "$work/named/ThemeSchema.generated.swift" "$consumer/Sources/Consumer/"
cat >"$consumer/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
  name: "NamedEntryPointConsumer",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "$root")],
  targets: [
    .executableTarget(
      name: "Consumer",
      dependencies: [.product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")],
      exclude: ["json-schema-codegen.json", "plugin.schema.json"],
      plugins: [.plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")]
    ),
    .executableTarget(
      name: "NoSchemas",
      exclude: ["json-schema-codegen.json"],
      plugins: [.plugin(name: "JSONSchemaCodegenPlugin", package: "swift-json-schema-codegen")]
    )
  ]
)
SWIFT
printf '%s\n' '{"version":1,"output":"models"}' \
  >"$consumer/Sources/Consumer/json-schema-codegen.json"
printf '%s\n' '{"type":"string"}' >"$consumer/Sources/Consumer/plugin.schema.json"
printf '%s\n' '{"version":1,"output":"models"}' \
  >"$consumer/Sources/NoSchemas/json-schema-codegen.json"
printf '%s\n' 'print("Configuration-only target passed.")' >"$consumer/Sources/NoSchemas/main.swift"
# A malformed parent config must not be discovered implicitly.
printf '%s\n' '{"version":999}' >"$consumer/json-schema-codegen.json"
cat >"$consumer/Sources/Consumer/main.swift" <<'SWIFT'
import JSONSchemaCodegen

let pluginValue: PluginSchema.Value = try PluginSchema.schema.parseAndValidate(instance: #""plugin""#)
precondition(pluginValue == "plugin")
let message = ThemeSchema.Message(text: "hello")
let constructed = ThemeSchema.Value(payload: message, choice: .text("choice"))
precondition(constructed.payload.text == "hello")
let parsed: ThemeSchema.Value = try ThemeSchema.schema.parseAndValidate(
  instance: #"{"payload":{"text":"parsed"},"choice":"yes"}"#
)
precondition(parsed.payload.text == "parsed")
guard case .text("yes") = parsed.choice else { fatalError("Wrong named case") }
print("Compiled CLI model names passed.")
SWIFT
use_runtime_checkout "$consumer" >"$work/runtime.log" 2>&1 ||
  { cat "$work/runtime.log" >&2; fail "Runtime checkout"; }
swift run --package-path "$consumer" --scratch-path "$root/.build/named-entry-consumer" Consumer \
  >"$work/consumer.log" 2>&1 ||
  { cat "$work/consumer.log" >&2; fail "Compiled model consumer"; }
grep -Fq 'Compiled CLI model names passed.' "$work/consumer.log"

# Editing the tracked target-local config regenerates the same source filename.
printf '%s\n' '{"version":1,"output":"tuples"}' \
  >"$consumer/Sources/Consumer/json-schema-codegen.json"
if swift build --package-path "$consumer" --scratch-path "$root/.build/named-entry-consumer" \
  --product Consumer >"$work/plugin-tuples.log" 2>&1; then
  fail "Plugin did not invalidate model output after changing config to tuples"
fi
grep -Fq 'Value' "$work/plugin-tuples.log" ||
  { cat "$work/plugin-tuples.log" >&2; fail "Expected missing model Value after mode switch"; }
printf '%s\n' '{"version":1,"output":"models"}' \
  >"$consumer/Sources/Consumer/json-schema-codegen.json"
swift run --package-path "$consumer" --scratch-path "$root/.build/named-entry-consumer" Consumer \
  >"$work/plugin-models.log" 2>&1 ||
  { cat "$work/plugin-models.log" >&2; fail "Plugin mode restoration"; }
grep -Fq 'Compiled CLI model names passed.' "$work/plugin-models.log"

swift run --package-path "$consumer" --scratch-path "$root/.build/named-entry-consumer" NoSchemas \
  >"$work/plugin-no-schemas.log" 2>&1 ||
  { cat "$work/plugin-no-schemas.log" >&2; fail "Plugin configuration-only target"; }
grep -Fq 'Configuration-only target passed.' "$work/plugin-no-schemas.log"
printf '%s\n' '{"version":2}' >"$consumer/Sources/NoSchemas/json-schema-codegen.json"
if swift build --package-path "$consumer" --scratch-path "$root/.build/named-entry-consumer" \
  --product NoSchemas >"$work/plugin-invalid-config.log" 2>&1; then
  fail "Plugin ignored malformed configuration in a target without schema inputs"
fi
grep -Fq 'json-schema-codegen.json: #/version:' "$work/plugin-invalid-config.log" ||
  { cat "$work/plugin-invalid-config.log" >&2; fail "Missing located plugin configuration error"; }

"$cli" --config "$work/batch-config.json" --output-directory "$work/batch" \
  "$work/inputs/other.schema.json" "$work/inputs/theme.schema.json"
"$cli" --config "$work/batch-config.json" --output-directory "$work/reordered" \
  "$work/inputs/theme.schema.json" "$work/inputs/other.schema.json"
diff -r "$work/batch" "$work/reordered"
cmp "$work/named/ThemeSchema.generated.swift" "$work/batch/ThemeSchema.generated.swift"

cat >"$work/inputs/node.schema.json" <<'JSON'
{"type":"object","properties":{"next":{"$ref":"#"}}}
JSON
printf '%s\n' '{"version":1,"output":"models","recursiveObjects":"immutableClasses"}' >"$config"
"$cli" --config "$config" --output-directory "$work/classes" "$work/inputs/node.schema.json"
grep -Eq 'final class `?Value`?' "$work/classes/NodeSchema.generated.swift"
expect_failure 'cycle' "$cli" --config "$config" --recursive-objects value-types \
  --output-directory "$work/rejected-cycle" "$work/inputs/node.schema.json"
[[ ! -e "$work/rejected-cycle" ]] || fail "Cycle error created output"

# Percent-encoded pointer characters and JSON Pointer escapes are not decoded twice.
cat >"$work/inputs/escaped.schema.json" <<'JSON'
{"$id":"https://example.com/escaped.json","type":"object","properties":{"a/b~c":{"type":"object","properties":{"text":{"type":"string"}}}}}
JSON
printf '%s\n' '{"version":1,"output":"models","typeNames":{"https://example.com/escaped.json#/properties/a%7E1b~0c":"EscapedPayload"}}' >"$config"
"$cli" --config "$config" --output-directory "$work/escaped" "$work/inputs/escaped.schema.json"
grep -Eq 'struct `?EscapedPayload`?' "$work/escaped/EscapedSchema.generated.swift"
printf '%s\n' 'Named-model entry-point checks passed.'
