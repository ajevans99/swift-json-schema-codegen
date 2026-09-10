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
[[ "$root/Sources/JSONSchemaCodegenCLI/SchemaFileNaming.swift" -ef \
  "$root/Plugins/JSONSchemaCodegenPlugin/SchemaFileNaming.swift" ]] ||
  fail "CLI and plugin must share their naming source"

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

# Reuse the realistic plugin fixtures instead of maintaining a second schema corpus.
fixtures="$root/Examples/PluginExample/Sources/PluginExample/Schemas"
mkdir -p "$work/shared/common" "$work/shared/app" "$work/shared/Nested"
cp "$fixtures/Common/design-tokens.schema.json" "$work/shared/common/design-tokens.schema.json"
cp "$fixtures/App/app-settings.schema.json" "$work/shared/app/app-settings.schema.json"
cp "$fixtures/theme.schema.json" "$work/shared/theme.schema.json"
cp "$fixtures/Nested/score.schema.json" "$work/shared/Nested/score.schema.json"

generate_shared() {
  "$cli" --output-directory "$1" \
    "$work/shared/theme.schema.json" "$work/shared/app/app-settings.schema.json" \
    "$work/shared/Nested/score.schema.json" "$work/shared/common/design-tokens.schema.json"
}

generate_shared "$work/shared-output"
grep -q 'public enum ThemeSchema' "$work/shared-output/ThemeSchema.generated.swift"
grep -q 'public enum AppSettingsSchema' "$work/shared-output/AppSettingsSchema.generated.swift"
grep -Fq '`fontFamily`' "$work/shared-output/ThemeSchema.generated.swift"
grep -Fq 'recentAccentColors' "$work/shared-output/AppSettingsSchema.generated.swift"

"$cli" --output-directory "$work/shared-reversed" \
  "$work/shared/common/design-tokens.schema.json" "$work/shared/Nested/score.schema.json" \
  "$work/shared/app/app-settings.schema.json" "$work/shared/theme.schema.json"
diff -r "$work/shared-output" "$work/shared-reversed"

grep -Fq '"minimum": 10' "$work/shared/common/design-tokens.schema.json"
sed 's/"minimum": 10/"minimum": 12/' "$work/shared/common/design-tokens.schema.json" \
  >"$work/updated.schema.json"
mv "$work/updated.schema.json" "$work/shared/common/design-tokens.schema.json"
generate_shared "$work/shared-changed"
for namespace in ThemeSchema AppSettingsSchema; do
  if cmp -s "$work/shared-output/$namespace.generated.swift" "$work/shared-changed/$namespace.generated.swift"; then
    fail "Changing shared typography did not change $namespace output"
  fi
done
grep -Fq '.minimum(12.0)' "$work/shared-changed/ThemeSchema.generated.swift"

expect_failure "$cli" --output-directory "$work/implicit-load" "$work/shared/theme.schema.json"
grep -Fq 'No files or URLs are loaded implicitly.' "$work/stderr"
grep -Fq "$work/shared/theme.schema.json: #/properties/colors/\$ref" "$work/stderr"
[[ ! -e "$work/implicit-load" ]] || fail "Implicit-load failure created output"

printf '%s\n' '{"type":' >"$work/input/z-malformed.schema.json"
expect_failure "$cli" --output-directory "$work/no-partial" \
  "$work/input/theme.schema.json" "$work/input/z-malformed.schema.json"
[[ ! -e "$work/no-partial" ]] || fail "Malformed batch created partial outputs"
grep -q 'z-malformed.schema.json: #' "$work/stderr"

mkdir "$work/source-error"
printf '%s\n' '{"$ref":"z-shared.schema.json"}' >"$work/source-error/a-consumer.schema.json"
printf '%s\n' '{"type":' >"$work/source-error/z-shared.schema.json"
expect_failure "$cli" --output-directory "$work/source-error-out" \
  "$work/source-error/a-consumer.schema.json" "$work/source-error/z-shared.schema.json"
grep -Fq "$work/source-error/z-shared.schema.json: #" "$work/stderr"
[[ ! -e "$work/source-error-out" ]] || fail "Malformed reference batch created output"

printf '%s\n' '{"type":"string","minLength":-1}' >"$work/source-error/z-shared.schema.json"
expect_failure "$cli" --output-directory "$work/source-error-out" \
  "$work/source-error/a-consumer.schema.json" "$work/source-error/z-shared.schema.json"
grep -Fq "$work/source-error/z-shared.schema.json: #/minLength" "$work/stderr"
if grep -Fq "$work/source-error/a-consumer.schema.json" "$work/stderr"; then
  fail "A referenced definition's error was incorrectly attributed to its consumer"
fi
[[ ! -e "$work/source-error-out" ]] || fail "Invalid reference batch created output"

printf '%s\n' '{"type":"boolean"}' >"$work/input/theme.schema.json"
expect_failure "$cli" --output-directory "$work/generated" \
  "$work/input/theme.schema.json" "$work/input/z-malformed.schema.json"
cmp "$work/unchanged" "$work/generated/ThemeSchema.generated.swift"

printf '%s\n' '{"type":"object","properties":{"bad":{"$ref":"#"}}}' >"$work/input/recursive.schema.json"
expect_failure "$cli" --output-directory "$work/recursive" "$work/input/recursive.schema.json"
grep -Fq '#/properties/bad/$ref' "$work/stderr"
[[ ! -e "$work/recursive" ]] || fail "Recursive schema created output"

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

mkdir "$work/cycle"
printf '%s\n' '{"$ref":"b-cycle.schema.json"}' >"$work/cycle/a-cycle.schema.json"
printf '%s\n' '{"$ref":"a-cycle.schema.json"}' >"$work/cycle/b-cycle.schema.json"
expect_failure "$cli" --output-directory "$work/cycle-out" \
  "$work/cycle/a-cycle.schema.json" "$work/cycle/b-cycle.schema.json"
grep -Fq "$work/cycle/b-cycle.schema.json: #/\$ref: Recursive reference cannot be represented" "$work/stderr"
[[ ! -e "$work/cycle-out" ]] || fail "Cycle failure created output"

mkdir "$work/duplicate-id"
printf '%s\n' '{"$id":"https://example.com/duplicate.json","type":"string"}' >"$work/duplicate-id/a.schema.json"
printf '%s\n' '{"$id":"https://example.com/duplicate.json","type":"integer"}' >"$work/duplicate-id/b.schema.json"
expect_failure "$cli" --output-directory "$work/duplicate-id-out" \
  "$work/duplicate-id/a.schema.json" "$work/duplicate-id/b.schema.json"
grep -Fq "$work/duplicate-id/b.schema.json: #/\$id: Duplicate schema resource URI" "$work/stderr"
[[ ! -e "$work/duplicate-id-out" ]] || fail "Duplicate ID failure created output"

swift run --package-path "$root/Examples/PluginExample" PluginExample \
  >"$work/example.stdout" 2>"$work/example.stderr" ||
  { cat "$work/example.stderr" >&2; fail "External plugin example"; }
grep -q 'Plugin example passed: Midnight, dark=true, score=42' "$work/example.stdout"
grep -q 'Plugin shared refs passed: mode=dark, body=Inter, accents=2' "$work/example.stdout"
if grep -Ei 'unhandled|deprecated' "$work/example.stderr"; then
  fail "Plugin example emitted unhandled-file or deprecated-API warnings"
fi

printf 'CLI and plugin smoke tests passed.\n'
