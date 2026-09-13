#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="$root/Examples/MetaSchemaExample"
runtime="${JSON_SCHEMA_RUNTIME_PATH:-}"

if [[ -z "$runtime" && -d "$root/Packages/swift-json-schema" ]]; then
  runtime="$root/Packages/swift-json-schema"
fi

if [[ -z "$runtime" ]]; then
  printf '%s\n' 'No local runtime override; using the existing SwiftPM dependency configuration.'
  exit 0
fi

if [[ ! -f "$runtime/Package.swift" ]]; then
  printf 'FAIL: JSON Schema runtime has no Package.swift: %s\n' "$runtime" >&2
  exit 1
fi
runtime="$(cd "$runtime" && pwd -P)"

editable="$example/Packages/swift-json-schema"
if [[ -e "$editable" || -L "$editable" ]]; then
  if [[ -d "$editable" && "$(cd "$editable" && pwd -P)" == "$runtime" ]]; then
    printf '%s\n' 'Meta-schema example already uses the selected editable runtime.'
    exit 0
  fi
  printf '%s\n' \
    'FAIL: The example already has a different or broken editable runtime.' \
    'Review it, then run swift package --package-path Examples/MetaSchemaExample unedit swift-json-schema before selecting another checkout.' >&2
  exit 1
fi

mkdir -p "$example/.build"
log="$(mktemp "$example/.build/runtime-edit.XXXXXX")"
trap 'rm -f -- "$log"' EXIT

if ! swift package --package-path "$example" edit swift-json-schema --path "$runtime" >"$log" 2>&1; then
  cat "$log" >&2
  if grep -Fq "Could not find dependency 'swift-json-schema'" "$log"; then
    swift package --package-path "$example" resolve
    swift package --package-path "$example" edit swift-json-schema --path "$runtime"
  else
    exit 1
  fi
fi

printf '%s\n' 'Meta-schema example configured with the selected editable runtime.'
