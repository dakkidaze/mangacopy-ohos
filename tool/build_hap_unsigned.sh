#!/usr/bin/env bash
# 构建未签名 HAP。
#
# 背景：CPF-Flutter 的 ohos 构建在 hvigor 成功产出 HAP 后，仍会因
# ohos/build-profile.json5 的 app.signingConfigs 为空而报错并以非零码退出
# （见 flutter_tools/lib/src/ohos/hvigor.dart 的 checkOhosSignedInfo）。
# 因此本脚本忽略 flutter 的退出码，改以“产物是否存在”判定成功。
#
# 用法: tool/build_hap_unsigned.sh [debug|release]   (默认 release)
set -uo pipefail

FLUTTER_OHOS_HOME="${FLUTTER_OHOS_HOME:-/home/dakki/flutter_ohos}"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-/home/dakki/command-line-tools/command-line-tools/sdk}"
MODE="${1:-release}"

export PATH="$FLUTTER_OHOS_HOME/bin:$PATH"
export DEVECO_SDK_HOME

cd "$(dirname "$0")/.." || exit 2

echo ">> flutter build hap --$MODE（签名校验报错可忽略，见脚本注释）"
flutter build hap --"$MODE" || true

HAP="$(find ohos -name '*-unsigned.hap' 2>/dev/null | head -1)"
if [ -n "$HAP" ]; then
  echo "OK: $HAP ($(du -h "$HAP" | cut -f1))"
else
  echo "FAILED: 未找到未签名 HAP" >&2
  exit 1
fi
