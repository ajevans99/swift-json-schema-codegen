#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$root/.build"
work="$(mktemp -d "$root/.build/xcode-smoke.XXXXXX")"
printf 'Xcode smoke artifacts: %s\n' "$work"

# Fresh DerivedData ensures a previously built CLI cannot hide plugin tool lookup failures.
xcodebuild \
  -workspace "$root/Examples/PluginExample/PluginExample.xcworkspace" \
  -scheme PluginExample \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$work/DerivedData" \
  -clonedSourcePackagesDirPath "$work/SourcePackages" \
  -resultBundlePath "$work/build.xcresult" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -jobs 4 \
  build >"$work/build.log" 2>&1 || {
    cat "$work/build.log" >&2
    exit 1
  }

"$work/DerivedData/Build/Products/Debug/PluginExample" >"$work/example.stdout" 2>"$work/example.stderr" || {
  cat "$work/example.stderr" >&2
  exit 1
}
grep -Fq 'Plugin example passed: Midnight, dark=true, score=42' "$work/example.stdout"
grep -Fq 'Plugin shared refs passed: mode=dark, body=Inter, accents=2' "$work/example.stdout"
printf 'Xcode plugin smoke tests passed.\n'
