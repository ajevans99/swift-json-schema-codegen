#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/Tests/Support/runtime.sh"
example="$root/Examples/OpenAPIExample"
use_runtime_checkout "$example"
mkdir -p "$root/.build"
work="$root/.build/openapi-smoke-$$-$RANDOM"
mkdir "$work"
trap 'rm -rf -- "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

swift build --package-path "$example" --product openapi-generate >"$work/generator-build.log" 2>&1 ||
  { cat "$work/generator-build.log" >&2; fail "OpenAPI generator build"; }
bin="$(swift build --package-path "$example" --show-bin-path)"
generator="$bin/openapi-generate"
[[ -x "$generator" ]] || fail "OpenAPI generator executable was not produced"

mkdir -p "$work/consumer/Sources/OpenAPIConsumer"
source="$work/consumer/Sources/OpenAPIConsumer/StyleAPI.generated.swift"
"$generator" "$example/Fixtures/style-api.openapi.json" >"$source" 2>"$work/generator.stderr" ||
  { cat "$work/generator.stderr" >&2; fail "OpenAPI component generation"; }
[[ -s "$source" ]] || fail "OpenAPI generator produced no Swift source"
grep -Fq 'public enum ThemeSchema' "$source" || fail "Missing allOf component namespace"
grep -Fq 'public enum ThemeResponseSchema' "$source" || fail "Missing oneOf component namespace"
grep -Fq 'public enum Union1' "$source" || fail "Missing generated union declaration"
if grep -Fq "$root" "$source"; then
  fail "Generated source contains a developer-specific repository path"
fi
"$generator" "$example/Fixtures/style-api.openapi.json" >"$work/repeated.swift" 2>"$work/generator.stderr" ||
  { cat "$work/generator.stderr" >&2; fail "Repeated generation"; }
cmp "$source" "$work/repeated.swift" || fail "OpenAPI generation is not deterministic"

# Package paths stay relative to this script's repository-local staging area.
# Generated consumers can use the same editable runtime as the root package.
cat >"$work/consumer/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import Foundation
import PackageDescription

let runtime = ProcessInfo.processInfo.environment["JSON_SCHEMA_RUNTIME_PATH"]
let package = Package(
  name: "OpenAPIConsumer",
  platforms: [.macOS(.v14)],
  dependencies: [
    runtime.map { .package(name: "swift-json-schema", path: $0) } ?? .package(path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "OpenAPIConsumer",
      dependencies: [
        runtime == nil
          ? .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
          : .product(name: "JSONSchemaBuilder", package: "swift-json-schema")
      ]
    )
  ]
)
SWIFT
cp "$example/Consumer/main.swift" "$work/consumer/Sources/OpenAPIConsumer/main.swift"
swift run --package-path "$work/consumer" \
  --scratch-path "$root/.build/openapi-consumer" OpenAPIConsumer \
  "$example/Fixtures/theme.json" >"$work/consumer.stdout" 2>"$work/consumer.stderr" ||
  { cat "$work/consumer.stdout" >&2; cat "$work/consumer.stderr" >&2; fail "Generated OpenAPI consumer build/run"; }
grep -Fq 'OpenAPI example passed:' "$work/consumer.stdout" ||
  fail "Generated consumer did not complete its runtime checks"

"$generator" "$example/Fixtures/style-api.openapi.json" --output-style models \
  >"$source" 2>"$work/models-generator.stderr" ||
  { cat "$work/models-generator.stderr" >&2; fail "Named OpenAPI component generation"; }
grep -Eq 'public struct `?Value`?' "$source" || fail "Missing named root model"
grep -Eq 'case `?ready`?[(]' "$source" || fail "Missing semantic response cases"
"$generator" "$example/Fixtures/style-api.openapi.json" --output-style models \
  >"$work/repeated-models.swift" 2>"$work/models-generator.stderr" ||
  { cat "$work/models-generator.stderr" >&2; fail "Repeated named generation"; }
cmp "$source" "$work/repeated-models.swift" || fail "Named OpenAPI output is not deterministic"
swift run --package-path "$work/consumer" \
  --scratch-path "$root/.build/openapi-consumer-models" -Xswiftc -DNAMED_MODELS OpenAPIConsumer \
  "$example/Fixtures/theme.json" >"$work/models-consumer.stdout" 2>"$work/models-consumer.stderr" ||
  { cat "$work/models-consumer.stdout" >&2; cat "$work/models-consumer.stderr" >&2; fail "Named OpenAPI consumer build/run"; }
grep -Fq 'OpenAPI example passed:' "$work/models-consumer.stdout" ||
  fail "Named consumer did not complete its runtime checks"

printf '%s\n' '{"openapi":"3.0.3","components":{"schemas":{"Name":{"type":"string","nullable":true}}}}' \
  >"$work/unsupported.openapi.json"
if "$generator" "$work/unsupported.openapi.json" >"$work/invalid.swift" 2>"$work/invalid.stderr"; then
  fail "OpenAPI 3.0 must not be accepted"
fi
[[ ! -s "$work/invalid.swift" ]] || fail "Unsupported input emitted partial Swift source"
grep -Fq '#/openapi' "$work/invalid.stderr" || fail "Expected a located OpenAPI version diagnostic"
grep -Fq 'OpenAPI 3.1.x' "$work/invalid.stderr" || fail "Expected an explicit supported-version diagnostic"

cat "$work/consumer.stdout"
cat "$work/models-consumer.stdout"
printf '%s\n' 'OpenAPI smoke tests passed in tuple and named modes'
