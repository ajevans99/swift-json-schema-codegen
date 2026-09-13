#!/usr/bin/env bash

if [[ -z "${JSON_SCHEMA_RUNTIME_PATH:-}" && -d "$root/Packages/swift-json-schema" ]]; then
  JSON_SCHEMA_RUNTIME_PATH="$root/Packages/swift-json-schema"
fi
if [[ -n "${JSON_SCHEMA_RUNTIME_PATH:-}" ]]; then
  [[ -f "$JSON_SCHEMA_RUNTIME_PATH/Package.swift" ]] || {
    echo "JSON_SCHEMA_RUNTIME_PATH must point to a swift-json-schema package." >&2
    exit 1
  }
  JSON_SCHEMA_RUNTIME_PATH="$(cd "$JSON_SCHEMA_RUNTIME_PATH" && pwd -P)"
  export JSON_SCHEMA_RUNTIME_PATH
fi

use_runtime_checkout() {
  local package="$1"
  [[ -n "${JSON_SCHEMA_RUNTIME_PATH:-}" ]] || return 0
  local editable="$package/Packages/swift-json-schema"
  if [[ -e "$editable" ]]; then
    [[ "$(cd "$editable" && pwd -P)" == "$JSON_SCHEMA_RUNTIME_PATH" ]] || {
      echo "Existing editable runtime in $package differs from JSON_SCHEMA_RUNTIME_PATH." >&2
      return 1
    }
  else
    swift package --package-path "$package" edit swift-json-schema \
      --path "$JSON_SCHEMA_RUNTIME_PATH"
  fi
}
