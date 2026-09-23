#!/usr/bin/env bash
# astra-diet 安装器：把 Codex 的默认模型、子代理钉位与等待行为合并进配置。
# 全程只做「合并」，不整文件覆盖；改动前先备份，并打印逐项变化摘要。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$REPO/lib/astra_diet.py"

# 优先选一个带 TOML 解析器的解释器（3.11+ 自带 tomllib；macOS 的 /usr/bin/python3 是 3.9）
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
say()  { printf '%s\n' "$*"; }
hr()   { printf '%.0s─' {1..64}; printf '\n'; }

# ---------------------------------------------------------------- 默认值
MODE=""
PROJECT=""
CODEX_HOME_OVERRIDE=""
ROOT_MODEL="gpt-6-astra"
ROOT_EFFORT="medium"
SUB_MODEL="gpt-6-sol"
SUB_EFFORT="medium"
WAIT_MINUTES="25"
INSTALL_AGENTS_MD=1
ASSUME_YES=0
DRY_RUN=0
VERIFY_ONLY=0

usage() {
  cat <<'EOF'
astra-diet — 安装 Codex 省用量配置

用法
  ./install.sh [选项]

模式（二选一，默认交互询问；非交互时必须显式给出）
  -g, --global                写入 $CODEX_HOME（默认 ~/.codex）
  -p, --project <dir>         写入 <dir>/.codex，并把 AGENTS.md 放到 <dir>/AGENTS.md

参数
      --root-model <name>     根代理模型（默认 gpt-6-astra）
      --root-effort <level>   根代理档位 low|medium|high|xhigh（默认 medium）
      --sub-model <name>      子代理模型（默认 gpt-6-sol）
      --sub-effort <level>    子代理档位（默认 medium）
      --wait-minutes <n>      父代理等待子代理的上限分钟数（默认 25）
      --no-agents-md          不安装 AGENTS.md 纪律区块
      --codex-home <dir>      覆盖 $CODEX_HOME（仅 global 模式；也用于沙箱试跑）
  -n, --dry-run               只打印将要发生的变化，不写任何文件
  -y, --yes                   跳过所有询问，用上面给定的值直接执行
      --verify                不安装，只校验已安装内容是否与清单一致
  -h, --help                  显示本帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--global)      MODE="global"; shift ;;
    -p|--project)     MODE="project"; PROJECT="${2:-}"; shift 2 ;;
    --root-model)     ROOT_MODEL="$2"; shift 2 ;;
    --root-effort)    ROOT_EFFORT="$2"; shift 2 ;;
    --sub-model)      SUB_MODEL="$2"; shift 2 ;;
    --sub-effort)     SUB_EFFORT="$2"; shift 2 ;;
    --wait-minutes)   WAIT_MINUTES="$2"; shift 2 ;;
    --no-agents-md)   INSTALL_AGENTS_MD=0; shift ;;
    --codex-home)     CODEX_HOME_OVERRIDE="$2"; shift 2 ;;
    -n|--dry-run)     DRY_RUN=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    --verify)         VERIFY_ONLY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) say "未知参数：$1"; usage; exit 2 ;;
  esac
done

if [[ "$MODE" == "project" && -z "$PROJECT" ]]; then
  say "--project 需要一个目录参数"; exit 2
fi
if [[ -n "$CODEX_HOME_OVERRIDE" && "$MODE" == "project" ]]; then
  say "--codex-home 只适用于 global 模式"; exit 2
fi

CODEX_HOME="${CODEX_HOME_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"
IDLE_HOME="$CODEX_HOME"
[[ "$MODE" == "project" ]] && IDLE_HOME="$PROJECT/.codex"

if [[ "$VERIFY_ONLY" == "1" ]]; then
  "$PY" "$LIB" verify --codex-home "$IDLE_HOME"
  exit $?
fi

# ---------------------------------------------------------------- 交互
INTERACTIVE=0
if [[ "$ASSUME_YES" == "0" && -t 0 ]]; then
  INTERACTIVE=1
elif [[ "$ASSUME_YES" == "0" ]]; then
  say "提示：stdin 不是终端，按 --yes 的行为使用默认值。"
fi

ask() { # ask <提示> <默认值> -> stdout
  local prompt="$1" def="$2" ans
  if [[ "$INTERACTIVE" == "1" ]]; then
    read -r -p "$prompt [$def]: " ans || ans=""
    printf '%s' "${ans:-$def}"
  else
    printf '%s' "$def"
  fi
}

if [[ "$INTERACTIVE" == "1" ]]; then
  hr; say "astra-diet — Codex 省用量配置安装"; hr
  if [[ -z "$MODE" ]]; then
    ans="$(ask "写入位置：[g] 全局 \$CODEX_HOME / [p] 指定项目" "g")"
    case "$ans" in
      p|P|project) MODE="project"; PROJECT="$(ask "项目目录（绝对路径）" "$PWD")" ;;
      *)           MODE="global" ;;
    esac
  fi
  [[ "$MODE" == "project" ]] && IDLE_HOME="$PROJECT/.codex"
  ROOT_MODEL="$(ask "根代理模型（负责规划与最终决策）" "$ROOT_MODEL")"
  ROOT_EFFORT="$(ask "根代理推理档位 low|medium|high|xhigh" "$ROOT_EFFORT")"
  SUB_MODEL="$(ask "子代理模型（负责探索/检索/核验）" "$SUB_MODEL")"
  SUB_EFFORT="$(ask "子代理推理档位 low|medium|high|xhigh" "$SUB_EFFORT")"
  WAIT_MINUTES="$(ask "父代理等待子代理的上限（分钟，建议 <30 以命中提示缓存）" "$WAIT_MINUTES")"
  ans="$(ask "安装 AGENTS.md 子代理纪律区块？[Y/n]" "Y")"
  case "$ans" in n|N|no) INSTALL_AGENTS_MD=0 ;; esac
fi

# ---------------------------------------------------------------- 预检
[[ -z "$MODE" ]] && MODE="global"
hr; say "预检"
say "  python：$("$PY" -V 2>&1 | awk '{print $2}')  ($PY)"
if command -v codex >/dev/null 2>&1; then
  VER="$(codex --version 2>/dev/null | awk '{print $NF}')"
  say "  codex-cli $VER"
  MAJ="${VER%%.*}"; REST="${VER#*.}"; MIN="${REST%%.*}"
  if [[ "${MAJ:-0}" -eq 0 && "${MIN:-0}" -lt 150 ]]; then
    say "  ! 版本低于 0.150：本配置使用的 [features.multi_agent_v2] 与角色路由语义在该版本之后才稳定，建议先 codex update"
  fi
else
  say "  ! 未找到 codex 命令：配置仍会写入，但请在目标机器上确认版本"
fi
if [[ "$MODE" == "project" ]]; then
  [[ -d "$PROJECT" ]] || { say "  ! 项目目录不存在：$PROJECT"; exit 1; }
  say "  ! 项目级 .codex/config.toml 只对「受信任项目」生效；首次进入时 Codex 会要求你确认信任"
  say "  ! 项目内的 .codex/backups/ 建议加进 .gitignore（本工具不代改）"
else
  [[ -d "$CODEX_HOME" ]] || say "  ! $CODEX_HOME 不存在，将创建"
fi
if [[ -f "$IDLE_HOME/config.toml" ]] && grep -qE '^[[:space:]]*default_subagent_model[[:space:]]*=' "$IDLE_HOME/config.toml"; then
  say "  ! 检测到 [agents] default_subagent_model：与 agents/default.toml 同时存在时以文件为准，该键会被忽略"
fi

# ---------------------------------------------------------------- 确认
hr; say "即将写入"
for t in "config.toml" "agents/default.toml"; do say "  $IDLE_HOME/$t"; done
if [[ "$INSTALL_AGENTS_MD" == "1" ]]; then
  if [[ "$MODE" == "project" ]]; then say "  $PROJECT/AGENTS.md"; else say "  $IDLE_HOME/AGENTS.md"; fi
else
  say "  (跳过 AGENTS.md)"
fi
say "  备份目录：$IDLE_HOME/backups/astra-diet-<UTC 时间戳>/"
say "  根代理：$ROOT_MODEL / $ROOT_EFFORT    子代理：$SUB_MODEL / $SUB_EFFORT    等待上限：${WAIT_MINUTES} 分钟"
if [[ "$INTERACTIVE" == "1" && "$DRY_RUN" == "0" ]]; then
  ans="$(ask "继续？[Y/n]" "Y")"
  case "$ans" in n|N|no) say "已取消"; exit 0 ;; esac
fi

# ---------------------------------------------------------------- 执行
ARGS=(apply --repo "$REPO" --codex-home "$IDLE_HOME"
      --mode "$MODE" --root-model "$ROOT_MODEL" --root-effort "$ROOT_EFFORT"
      --sub-model "$SUB_MODEL" --sub-effort "$SUB_EFFORT" --wait-minutes "$WAIT_MINUTES")
[[ "$MODE" == "project" ]] && ARGS+=(--project "$PROJECT")
[[ "$INSTALL_AGENTS_MD" == "0" ]] && ARGS+=(--no-agents-md)
[[ "$DRY_RUN" == "1" ]] && ARGS+=(--dry-run)

hr; say "变更摘要（+ 新增　~ 修改　= 未变　! 提醒）"; hr
"$PY" "$LIB" "${ARGS[@]}"
rc=$?
hr
if [[ "$DRY_RUN" == "1" ]]; then
  say "dry-run 完成，未改动任何文件。去掉 -n 即可真正写入。"
elif [[ "$rc" == "0" ]]; then
  say "安装完成。回滚：./uninstall.sh ${MODE:+-${MODE:0:1}} ${PROJECT:+"$PROJECT"}"
  say "校验：./install.sh --verify ${MODE:+-${MODE:0:1}} ${PROJECT:+"$PROJECT"}"
fi
exit "$rc"
