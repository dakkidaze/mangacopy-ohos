#!/usr/bin/env bash
# 上游变更跟踪（本地手动运行）。
#
# 背景：本项目的 API 逻辑参考 copymanga-copy20（无 .kt 源码，只有 smali/APK）
# 与 manxia-extensions-source（干净 JSON）。因 GitHub 无鸿蒙套件，不做 CI，
# 改为本地脚本：拉取上游信号，与本仓 sources/copymanga.api.json 对比，产出变更报告。
#
# 用法: tools/upstream_watch.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
REPORT="tools/.upstream_report.md"
LOCAL="sources/copymanga.api.json"
MANXIA_URL="https://raw.githubusercontent.com/DaLongZhuaZi/manxia-extensions-source/master/com.manxia.extension.zh.copymangawebview/source.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

{
  echo "# 上游变更报告"
  echo
  echo "- 生成时间：$(date '+%F %T')"
  echo "- 本地契约：\`$LOCAL\`"
  echo
} > "$REPORT"

# ---- 1) manxia copymanga source.json ----
{
  echo "## 1. manxia copymanga source.json"
  echo
} >> "$REPORT"

if curl -fsSL -m 30 "$MANXIA_URL" -o "$TMP/manxia.json" 2>/dev/null; then
  python3 - "$LOCAL" "$TMP/manxia.json" >> "$REPORT" <<'PY'
import json, sys
local = json.load(open(sys.argv[1]))
m = json.load(open(sys.argv[2]))
lver = local.get('apiVersionHeader')
mver = (m.get('network') or {}).get('headers', {}).get('Version')
print(f"- 本地 Version 头：`{lver}`")
print(f"- manxia Version 头：`{mver}`")
print(f"- Version 是否一致：{'是' if lver == mver else '**否 —— 需检查**'}")
print()
mdom = set()
alts = (m.get('metadata') or {}).get('alternativeUrls') or {}
for v in alts.values():
    try:
        from urllib.parse import urlparse
        h = urlparse(v).hostname
        if h: mdom.add(h)
    except Exception:
        pass
settings = (m.get('settings') or {}).get('domain', {}).get('options') or []
for o in settings:
    v = o.get('value') if isinstance(o, dict) else None
    if v:
        try:
            from urllib.parse import urlparse
            h = urlparse(v).hostname
            if h: mdom.add(h)
        except Exception:
            pass
local_dom = set(local.get('domains', {}).get('commentCapable', [])) | set(local.get('domains', {}).get('hotNoComment', []))
only_up = sorted(mdom - local_dom)
only_local = sorted(local_dom - mdom)
print(f"- manxia 有、本地无的域（{len(only_up)}）：{', '.join(only_up) if only_up else '无'}")
print(f"- 本地有、manxia 无的域（{len(only_local)}）：{', '.join(only_local) if only_local else '无'}")
print()
lu = set(f"{m.get('metadata',{}).get('name','')}")
print(f"- manxia extension version：`{m.get('metadata', {}).get('version')}`")
PY
else
  echo "- **拉取失败**（网络？）" >> "$REPORT"
fi

echo >> "$REPORT"

# ---- 2) copymanga-copy20 版本 ----
{
  echo "## 2. copymanga-copy20"
  echo
} >> "$REPORT"
if command -v gh >/dev/null 2>&1; then
  gh release list -R LittleSurvival/copymanga-copy20 -L 5 >> "$REPORT" 2>&1 || echo "- gh 查询失败" >> "$REPORT"
else
  echo "- 未安装 gh，跳过" >> "$REPORT"
fi

echo >> "$REPORT"

# ---- 3) 官方 App 版本（官网下载页） ----
{
  echo "## 3. 官方 App 版本"
  echo
} >> "$REPORT"
if curl -fsSL -m 30 "https://www.mangacopy.com/download" -o "$TMP/official.html" 2>/dev/null; then
  grep -oiE 'V?[0-9]+\.[0-9]+\.[0-9]+' "$TMP/official.html" | sort -u | head -10 >> "$REPORT" || echo "- 未解析到版本号" >> "$REPORT"
else
  echo "- **拉取失败**" >> "$REPORT"
fi

echo >> "$REPORT"
echo "> 有差异时：人工核对后更新 \`sources/copymanga.api.json\`，再触发构建。" >> "$REPORT"

echo "报告已写入 $REPORT"
