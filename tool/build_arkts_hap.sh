#!/usr/bin/env bash
# Build the pure-ArkTS HarmonyOS project under harmony/ (unsigned HAP).
# Does NOT touch tool/build_hap_unsigned.sh (the Flutter pipeline).
set -euo pipefail

export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/home/dakki/command-line-tools/command-line-tools/sdk}"
export PATH="/home/dakki/command-line-tools/command-line-tools/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/harmony"

echo "==> ohpm install --all"
ohpm install --all

echo "==> hvigorw assembleHap"
./hvigorw assembleHap --mode module -p product=default -p module=entry@default --no-daemon

echo "==> Artifacts:"
find entry/build/default/outputs -name '*.hap' -type f 2>/dev/null | while read -r hap; do
  echo "$hap  ($(du -h "$hap" | cut -f1))"
done
