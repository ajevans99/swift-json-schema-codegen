#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/Tests/Support/runtime.sh"
export NAMED_MODELS_REPOSITORY="$root"
use_runtime_checkout "$root/Tests/NamedModels"

work="$root/.build/shared-model-fixture-$$"
mkdir -p "$work/Sources/GeneratedModels" "$work/Sources/NamedModelConsumer"
trap 'rm -rf -- "$work"' EXIT
cp "$root/Tests/NamedModels/Consumer/Package.swift" "$work/Package.swift"
cp "$root/Tests/NamedModels/Consumer/SharedMain.swift" "$work/Sources/NamedModelConsumer/main.swift"
swift run --package-path "$root/Tests/NamedModels" GenerateNamedModels \
  "$work/Sources/GeneratedModels" --shared-only
swift run --package-path "$work" --scratch-path "$root/.build/shared-model-consumer" NamedModelConsumer
