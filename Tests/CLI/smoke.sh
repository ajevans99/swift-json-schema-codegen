#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$root/.build"
work="$root/.build/cli-smoke-$$-$RANDOM"
mkdir "$work"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@" >"$work/stdout" 2>"$work/stderr"; then
    fail "Expected nonzero exit: $*"
  fi
  [[ -s "$work/stderr" ]] || fail "Expected a diagnostic on stderr: $*"
}

if [[ -n "${CODEGEN_BIN:-}" ]]; then
  cli="$CODEGEN_BIN"
else
  swift build --package-path "$root" --product json-schema-codegen >"$work/build.log" 2>&1 ||
    { cat "$work/build.log" >&2; fail "CLI build"; }
  bin="$(swift build --package-path "$root" --show-bin-path)"
  cli="$bin/json-schema-codegen"
fi
[[ -x "$cli" ]] || fail "CLI executable not found: $cli"

# Both targets must compile the same naming source.
diff -u \
  <(sed '/^\/\/ Keep this contract in sync/d' "$root/Sources/JSONSchemaCodegenCLI/SchemaFileNaming.swift") \
  <(sed '/^\/\/ Keep this contract in sync/d' "$root/Plugins/JSONSchemaCodegenPlugin/SchemaFileNaming.swift")

"$cli" --help >"$work/help"
grep -q 'USAGE: json-schema-codegen' "$work/help"
"$cli" -h >"$work/short-help"
cmp "$work/help" "$work/short-help"
expect_failure "$cli"
expect_failure "$cli" --output-directory
expect_failure "$cli" --unknown

mkdir "$work/input"
printf '%s\n' '{"type":"string","minLength":1}' >"$work/input/theme.schema.json"
printf '%s\n' '{"type":"integer","minimum":0}' >"$work/input/user-score.schema.json"
"$cli" --output-directory "$work/generated" -- \
  "$work/input/user-score.schema.json" "$work/input/theme.schema.json"
grep -q 'public enum ThemeSchema' "$work/generated/ThemeSchema.generated.swift"
grep -q 'some JSONSchemaComponent<String>' "$work/generated/ThemeSchema.generated.swift"
grep -q 'public enum UserScoreSchema' "$work/generated/UserScoreSchema.generated.swift"
grep -q 'some JSONSchemaComponent<Int>' "$work/generated/UserScoreSchema.generated.swift"
grep -qx 'import JSONSchema' "$work/generated/ThemeSchema.generated.swift"
grep -qx 'import JSONSchemaBuilder' "$work/generated/ThemeSchema.generated.swift"

mkdir "$work/shapes"
printf '%s\n' 'true' >"$work/shapes/allow.schema.json"
printf '%s\n' '{}' >"$work/shapes/any-value.schema.json"
printf '%s\n' '{"type":"null"}' >"$work/shapes/null.schema.json"
printf '%s\n' '{"type":"object"}' >"$work/shapes/empty-object.schema.json"
printf '%s\n' '{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}' \
  >"$work/shapes/singleton.schema.json"
"$cli" --output-directory "$work/shape-output" "$work/shapes/"*.schema.json
grep -Fq 'some JSONSchemaComponent<JSONValue>' "$work/shape-output/AllowSchema.generated.swift"
grep -Fq 'some JSONSchemaComponent<JSONValue>' "$work/shape-output/AnyValueSchema.generated.swift"
grep -Fq 'some JSONSchemaComponent<Void>' "$work/shape-output/NullSchema.generated.swift"
grep -Fq 'some JSONSchemaComponent<Void>' "$work/shape-output/EmptyObjectSchema.generated.swift"
grep -Fq 'some JSONSchemaComponent<String>' "$work/shape-output/SingletonSchema.generated.swift"

"$cli" --output-directory "$work/reversed" \
  "$work/input/theme.schema.json" "$work/input/user-score.schema.json"
diff -r "$work/generated" "$work/reversed"
touch -t 200101010000 "$work/generated/ThemeSchema.generated.swift"
cp -p "$work/generated/ThemeSchema.generated.swift" "$work/unchanged"
"$cli" --output-directory "$work/generated" "$work/input/theme.schema.json"
cmp "$work/unchanged" "$work/generated/ThemeSchema.generated.swift"
[[ ! "$work/generated/ThemeSchema.generated.swift" -nt "$work/unchanged" ]] ||
  fail "Unchanged output was rewritten"

printf '%s\n' '{"type":' >"$work/input/z-malformed.schema.json"
expect_failure "$cli" --output-directory "$work/no-partial" \
  "$work/input/theme.schema.json" "$work/input/z-malformed.schema.json"
[[ ! -e "$work/no-partial" ]] || fail "Malformed batch created partial outputs"
grep -q 'z-malformed.schema.json: #' "$work/stderr"

printf '%s\n' '{"type":"boolean"}' >"$work/input/theme.schema.json"
expect_failure "$cli" --output-directory "$work/generated" \
  "$work/input/theme.schema.json" "$work/input/z-malformed.schema.json"
cmp "$work/unchanged" "$work/generated/ThemeSchema.generated.swift"

printf '%s\n' '{"type":"object","properties":{"bad":{"$ref":"#"}}}' >"$work/input/unsupported.schema.json"
expect_failure "$cli" --output-directory "$work/unsupported" "$work/input/unsupported.schema.json"
grep -Fq '#/properties/bad/$ref' "$work/stderr"
[[ ! -e "$work/unsupported" ]] || fail "Unsupported schema created output"

expect_failure "$cli" --output-directory "$work/missing" "$work/input/missing.schema.json"
grep -q 'missing.schema.json' "$work/stderr"
[[ ! -e "$work/missing" ]] || fail "Missing input created output"

printf '%s\n' '{"type":"string"}' >"$work/input/user_score.schema.json"
expect_failure "$cli" --output-directory "$work/collision" \
  "$work/input/user-score.schema.json" "$work/input/user_score.schema.json"
grep -q 'collides with' "$work/stderr"
[[ ! -e "$work/collision" ]] || fail "Filename collision created output"

mkdir "$work/input/other"
printf '%s\n' '{}' >"$work/input/other/Theme.schema.json"
expect_failure "$cli" --output-directory "$work/case-collision" \
  "$work/input/theme.schema.json" "$work/input/other/Theme.schema.json"
grep -q 'collides with' "$work/stderr"

for filename in '123.schema.json' 'bad.name.schema.json' 'bad--name.schema.json' \
  'bad name.schema.json' 'bad_.schema.json' 'bad.json'; do
  printf '%s\n' '{}' >"$work/input/$filename"
  expect_failure "$cli" --output-directory "$work/invalid-name" "$work/input/$filename"
  [[ ! -e "$work/invalid-name" ]] || fail "Invalid filename created output"
done

swift run --package-path "$root/Examples/PluginExample" PluginExample \
  >"$work/example.stdout" 2>"$work/example.stderr" ||
  { cat "$work/example.stderr" >&2; fail "External plugin example"; }
grep -q 'Plugin example passed: Midnight, dark=true, score=42' "$work/example.stdout"
if grep -Ei 'unhandled|deprecated' "$work/example.stderr"; then
  fail "Plugin example emitted unhandled-file or deprecated-API warnings"
fi

printf 'CLI and plugin smoke tests passed.\n'
