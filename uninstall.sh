#!/usr/bin/env bash
# astra-diet 卸载器：按安装时写下的清单精确回滚。
#   安装时被「修改」的文件 -> 写回备份
#   安装时被「新建」的文件 -> 删除
#   安装后又被你手工改过的文件 -> 默认跳过，需 --force
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$REPO/lib/astra_diet.py"

pick_python() {
  local c
  for c in python3.13 python3.12 python3.11 python3; do
    command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' >/dev/null 2>&1 && { echo "$c"; return; }
  done
  for c in python3.13 python3.12 python3.11 python3; do
    command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomli' >/dev/null 2>&1 && { echo "$c"; return; }
  done
  echo python3
}
PY="$(pick_python)"
say() { printf '%s\n' "$*"; }
hr()  { printf '%.0s─' {1..64}; printf '\n'; }

MODE=""
PROJECT=""
CODEX_HOME_OVERRIDE=""
BACKUP=""
DRY_RUN=0
FORCE=0
VERIFY_ONLY=0

usage() {
  cat <<'EOF'
astra-diet — 回滚安装

用法
  ./uninstall.sh [-g | -p <dir>] [选项]

定位备份
  -g, --global                目标为 $CODEX_HOME（默认 ~/.codex）
  -p, --project <dir>         目标为 <dir>/.codex（AGENTS.md 在 <dir>/AGENTS.md）
      --codex-home <dir>      覆盖 $CODEX_HOME（仅 global）
      --backup <dir>          显式指定某个备份目录（默认取最新的 astra-diet-*）

行为
  -n, --dry-run               只说明会做什么，不落盘
      --force                 即使文件在安装后被改过也强行回滚（先自行备份！）
      --verify                不卸载，只校验当前状态与清单是否一致
  -h, --help                  显示本帮助

说明
  回滚不会删除备份目录本身，方便再次安装或人工比对。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--global)    MODE="global"; shift ;;
    -p|--project)   MODE="project"; PROJECT="${2:-}"; shift 2 ;;
    --codex-home)   CODEX_HOME_OVERRIDE="$2"; shift 2 ;;
    --backup)       BACKUP="$2"; shift 2 ;;
    -n|--dry-run)   DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    --verify)       VERIFY_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) say "未知参数：$1"; usage; exit 2 ;;
  esac
done

if [[ "$MODE" == "project" && -z "$PROJECT" ]]; then say "--project 需要一个目录参数"; exit 2; fi
[[ -n "$BACKUP" && -n "$PROJECT" ]] && MODE="project"
[[ -z "$MODE" && -z "$BACKUP" ]] && MODE="global"
CODEX_HOME="${CODEX_HOME_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"
IDLE_HOME="$CODEX_HOME"
[[ "$MODE" == "project" ]] && IDLE_HOME="$PROJECT/.codex"

ARGS=()
if [[ -n "$BACKUP" ]]; then ARGS+=(--backup "$BACKUP"); fi
if [[ "$VERIFY_ONLY" == "1" ]]; then
  "$PY" "$LIB" verify --codex-home "$IDLE_HOME" "${ARGS[@]}"
  exit $?
fi

hr; say "astra-diet — 回滚"; hr
if [[ "$DRY_RUN" == "1" ]]; then
  say "（dry-run：只说明将发生什么）"
else
  say "注意：回滚前请确认没有正在运行的 Codex 会话在写这些文件。"
fi
ARGS+=(--codex-home "$IDLE_HOME")
[[ "$DRY_RUN" == "1" ]] && ARGS+=(--dry-run)
[[ "$FORCE" == "1" ]] && ARGS+=(--force)

"$PY" "$LIB" revert "${ARGS[@]}"
rc=$?
hr
if [[ "$rc" == "0" && "$DRY_RUN" == "0" ]]; then
  say "回滚完成。若想再次安装：./install.sh ${MODE:+-${MODE:0:1}} ${PROJECT:+"$PROJECT"}"
fi
exit "$rc"
