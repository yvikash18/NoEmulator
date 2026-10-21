#!/usr/bin/env bash
# Package module/ into a flashable KernelSU zip.
#
# The zip is just the contents of module/ at the archive root; KernelSU reads
# module.prop and runs customize.sh from there.
set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^version=//p' "$REPO/module/module.prop")"
OUT="$REPO/out/noemulator-$VERSION.zip"

sh "$REPO/tests/test_generate_rules.sh" >/dev/null || {
    echo "tests fail; not packaging" >&2
    exit 1
}

mkdir -p "$REPO/out"
rm -f "$OUT"
(cd "$REPO/module" && zip -qr "$OUT" .)

echo "$OUT"
