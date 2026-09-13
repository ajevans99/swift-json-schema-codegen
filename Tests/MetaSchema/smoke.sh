#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
example="$root/Examples/MetaSchemaExample"

python3 "$root/Tests/MetaSchema/check-fixtures.py"
bash "$root/Tests/MetaSchema/configure-runtime.sh"

mkdir -p "$example/.build"
work="$example/.build/meta-schema-smoke-$$-$RANDOM"
mkdir "$work"
trap 'rm -rf -- "$work"' EXIT

if ! swift run --package-path "$example" MetaSchemaExample \
  >"$work/stdout.log" 2>"$work/stderr.log"; then
  cat "$work/stdout.log" >&2
  cat "$work/stderr.log" >&2
  printf '%s\n' 'FAIL: Meta-schema plugin generation, consumer build, or runtime validation' >&2
  exit 1
fi

if ! grep -Fq 'Meta-schema example passed:' "$work/stdout.log"; then
  cat "$work/stdout.log" >&2
  printf '%s\n' 'FAIL: Meta-schema consumer did not complete its validation checks' >&2
  exit 1
fi

cat "$work/stdout.log"
printf '%s\n' 'Meta-schema smoke tests passed'
