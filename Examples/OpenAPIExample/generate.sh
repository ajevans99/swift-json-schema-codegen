#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="$root/.build/openapi-preview"
mkdir -p "$output"
temporary="$(mktemp "$output/StyleAPI.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT

swift run --package-path "$root/Examples/OpenAPIExample" openapi-generate \
  "$root/Examples/OpenAPIExample/Fixtures/style-api.openapi.json" >"$temporary"

mv "$temporary" "$output/StyleAPI.generated.swift"
printf 'Generated %s\n' "$output/StyleAPI.generated.swift"
