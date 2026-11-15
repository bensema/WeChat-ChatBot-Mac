#!/usr/bin/env bash
#
# 保持 hook/script.js 与 bridge/script.js 一致。
#
# hook/script.js 是唯一事实来源（GPL 上游脚本 + 本项目版本化适配 + R3）；
# bridge/script.js 是 bridge 运行时从「当前工作目录」读取的副本，两者不一致时
# 会出现「源码改了但真机行为没变」的假象。
#
# 用法：
#   bash scripts/sync_hook_script.sh           # 把 hook/script.js 复制到 bridge/script.js
#   bash scripts/sync_hook_script.sh --check   # 只校验，不一致时退出码 1
#   bash scripts/sync_hook_script.sh --quiet   # 校验/同步成功时不打印
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/hook/script.js"
DST="${ROOT_DIR}/bridge/script.js"

MODE="sync"
QUIET=0

usage() {
  cat <<'EOF'
用法：scripts/sync_hook_script.sh [选项]

选项：
  --check   只校验两个文件是否一致（不一致退出 1），不做修改
  --quiet   成功时不输出
  -h, --help
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --check) MODE="check" ;;
    --quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "未知参数：${arg}" >&2; exit 2 ;;
  esac
done

[[ -f "${SRC}" ]] || { echo "❌ 缺少 ${SRC}（唯一事实来源）" >&2; exit 1; }
[[ -f "${DST}" ]] || { echo "❌ 缺少 ${DST}（bridge 运行时副本）" >&2; exit 1; }

# macOS 自带 shasum；Linux CI 上回退到 sha256sum。
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "❌ 缺少 shasum 或 sha256sum，无法校验脚本副本" >&2
    exit 1
  fi
}

for script_name in script.js script-x86_64.js; do
  SRC="${ROOT_DIR}/hook/${script_name}"
  DST="${ROOT_DIR}/bridge/${script_name}"
  [[ -f "$SRC" ]] || { echo "Missing Hook: $SRC" >&2; exit 1; }
  if [[ "$MODE" == "sync" ]]; then
    cp -p "$SRC" "$DST"
    chmod 644 "$DST"
  fi
  [[ -f "$DST" ]] && [[ "$(sha256_file "$SRC")" == "$(sha256_file "$DST")" ]] \
    || { echo "Hook copy differs: $script_name; run scripts/sync_hook_script.sh" >&2; exit 1; }
  (( QUIET )) || echo "✅ hook/${script_name} 与 bridge/${script_name} 一致"
done

contact_src="${ROOT_DIR}/hook/contact-directory-x64.js"
contact_dst="${ROOT_DIR}/bridge/contact-directory-x64.js"
[[ -f "$contact_src" ]] || { echo "Missing x64 contact module: $contact_src" >&2; exit 1; }
if [[ "$MODE" == "sync" ]]; then
  cp -p "$contact_src" "$contact_dst"
  chmod 644 "$contact_dst"
fi
[[ -f "$contact_dst" ]] && [[ "$(sha256_file "$contact_src")" == "$(sha256_file "$contact_dst")" ]] \
  || { echo "Hook copy differs: contact-directory-x64.js; run scripts/sync_hook_script.sh" >&2; exit 1; }
(( QUIET )) || echo "✅ hook/contact-directory-x64.js 与 bridge/contact-directory-x64.js 一致"
