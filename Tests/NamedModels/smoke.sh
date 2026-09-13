#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/Tests/Support/runtime.sh"
export NAMED_MODELS_REPOSITORY="$root"
use_runtime_checkout "$root/Tests/NamedModels"

mkdir -p "$root/.build"
work="$(mktemp -d "$root/.build/named-models-XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/Sources/GeneratedModels" "$work/Sources/NamedModelConsumer"
cp "$root/Tests/NamedModels/Consumer/Package.swift" "$work/Package.swift"
cp "$root/Tests/NamedModels/Consumer/main.swift" "$work/Sources/NamedModelConsumer/main.swift"

swift run --package-path "$root/Tests/NamedModels" GenerateNamedModels \
  "$work/Sources/GeneratedModels"
swift run --package-path "$work" --scratch-path "$root/.build/named-model-consumer" NamedModelConsumer

bin="$(swift build --package-path "$work" --scratch-path "$root/.build/named-model-consumer" --show-bin-path)"
if swiftc -typecheck -I "$bin/Modules" -I "$bin" -F "$bin/PackageFrameworks" -F "$bin" \
  "$root/Tests/NamedModels/Consumer/MissingRequiredNullable.swift" >"$work/missing.log" 2>&1; then
  echo "FAIL: Required nullable initializer argument was defaulted." >&2
  exit 1
fi
if ! grep -Fq "missing argument for parameter 'nickname'" "$work/missing.log"; then
  cat "$work/missing.log" >&2
  echo "FAIL: Required-nullable consumer failed for an unrelated reason." >&2
  exit 1
fi
if swiftc -typecheck -I "$bin/Modules" -I "$bin" -F "$bin/PackageFrameworks" -F "$bin" \
  "$root/Tests/NamedModels/Consumer/ExposedReferenceAdapter.swift" >"$work/private.log" 2>&1; then
  echo "FAIL: Legacy reference adapter remained public in named mode." >&2
  exit 1
fi
if ! grep -Eq "Reference1.*(inaccessible|no member)|no member.*Reference1" "$work/private.log"; then
  cat "$work/private.log" >&2
  echo "FAIL: Adapter consumer failed for an unrelated reason." >&2
  exit 1
fi
echo "Named-model public API rejection checks passed."
