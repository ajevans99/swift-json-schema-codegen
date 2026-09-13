#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/Tests/Support/runtime.sh"
use_runtime_checkout "$root/Tests/Conformance"
suite="${JSON_SCHEMA_TEST_SUITE:-$root/.build/json-schema-test-suite}"
if [[ -z "${JSON_SCHEMA_TEST_SUITE:-}" && ! -d "$suite/tests/draft2020-12" ]]; then
  suite="$root/.build/checkouts/swift-json-schema/Tests/JSONSchemaTests/JSON-Schema-Test-Suite"
fi
[[ -d "$suite/tests/draft2020-12" ]] || {
  echo "Set JSON_SCHEMA_TEST_SUITE to a checkout of json-schema-org/JSON-Schema-Test-Suite." >&2
  exit 1
}
if [[ -d "$suite/.git" || -f "$suite/.git" ]]; then
  printf 'JSON Schema Test Suite revision: '
  git -C "$suite" rev-parse HEAD
fi
mkdir -p "$root/.build"
work="$(mktemp -d "$root/.build/conformance-XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/Sources/Conformance"
status=0
swift run --package-path "$root/Tests/Conformance" GenerateConformance \
  "$suite" "$work/Sources/Conformance" "$@" || status=1
[[ -f "$work/Sources/Conformance/main.swift" ]] || exit 1
cat >"$work/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import Foundation
import PackageDescription
let runtime = ProcessInfo.processInfo.environment["JSON_SCHEMA_RUNTIME_PATH"]
let package = Package(
  name: "Conformance",
  platforms: [.macOS(.v14)],
  dependencies: [runtime.map { .package(name: "swift-json-schema", path: $0) } ?? .package(path: "../..")],
  targets: [.executableTarget(
    name: "Conformance",
    dependencies: [runtime == nil
      ? .product(name: "JSONSchemaCodegen", package: "swift-json-schema-codegen")
      : .product(name: "JSONSchemaBuilder", package: "swift-json-schema")],
    exclude: ["generation-failures.txt"]
  )]
)
SWIFT
swift run --package-path "$work" --scratch-path "$root/.build/conformance-consumer" Conformance ||
  status=1
exit "$status"
