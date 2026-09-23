#!/usr/bin/env bash
# astra-diet 自测：覆盖 config.toml + agents/default.toml 的合并 / 幂等 / 回滚 / 漂移 / project 模式。
# 全部在 /tmp 沙箱里进行，不碰真实 ~/.codex。
#
# 注意：AGENTS.md 的写入路径不在本脚本覆盖范围内（部分环境会拦截脚本生成 AGENTS.md）。
# 该路径需要单独确认后再测。
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/lib/astra_diet.py"
FIX="$REPO/tests/fixtures"

PY=""
for c in python3.13 python3.12 python3.11 python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -z "$PY" ]] && PY=python3

OUT="${TMPDIR:-/tmp}/astra-diet-selftest"
mkdir -p "$OUT"
pass=0; fail=0
ok() { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL  %s  <<< %s\n' "$1" "$2"; fail=$((fail+1)); }
chk() { local d="$1"; shift; local out; out="$(eval "$@" 2>&1)"; if [[ $? -eq 0 ]]; then ok "$d"; else no "$d" "$out"; fi; }
sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
inst()   { bash "$REPO/install.sh" -g -y --no-agents-md --codex-home "$1" "${@:2}" > "$OUT/last.out" 2>&1; }
uninst() { bash "$REPO/uninstall.sh" -g --codex-home "$1" "${@:2}" > "$OUT/last_un.out" 2>&1; }

echo "interpreter: $PY"

echo; echo "══ T1 dry-run（复杂既有配置，不应落盘）"
W="$OUT/t1"; rm -rf "$W"; mkdir -p "$W"; cp "$FIX/config_existing.toml" "$W/config.toml"
B=$(sha "$W/config.toml")
inst "$W" -n; rc=$?
chk "T1 exit 0" "[ $rc -eq 0 ]"
chk "T1 config 未被写" "[ \"$(sha "$W/config.toml")\" = \"$B\" ]"
chk "T1 未创建 default.toml" "[ ! -e \"$W/agents/default.toml\" ]"
chk "T1 提示 default_subagent_model 冲突" "grep -q 'default_subagent_model' '$OUT/last.out'"
chk "T1 打印修改项" "grep -q 'model_reasoning_effort' '$OUT/last.out'"
chk "T1 打印 diff" "grep -q '^  --- diff ---' '$OUT/last.out'"

echo; echo "══ T2 真实安装（合并进既有 config）"
inst "$W"; rc=$?
chk "T2 exit 0" "[ $rc -eq 0 ]"
chk "T2 TOML 可解析" "$PY -c 'import tomllib;tomllib.loads(open(\"$W/config.toml\").read())'"
chk "T2 只有一张 [agents]" "[ $(grep -c '^\[agents\]$' "$W/config.toml") -eq 1 ]"
chk "T2 只有一张 [features.multi_agent_v2]" "[ $(grep -c '^\[features.multi_agent_v2\]$' "$W/config.toml") -eq 1 ]"
chk "T2 保留未知键" "grep -q 'custom_unknown_key' '$W/config.toml'"
chk "T2 保留并发设置" "grep -q 'max_concurrent_threads_per_session = 2' '$W/config.toml'"
chk "T2 保留既有 hide_spawn_agent_metadata" "grep -q 'hide_spawn_agent_metadata = false' '$W/config.toml'"
chk "T2 保留 wait_agent_enabled" "grep -q 'wait_agent_enabled = true' '$W/config.toml'"
chk "T2 root model 已改" "grep -q '^model = \"gpt-6-astra\"' '$W/config.toml'"
chk "T2 root effort 已改" "grep -q '^model_reasoning_effort = \"medium\"' '$W/config.toml'"
chk "T2 等待值已写" "grep -q 'default_wait_timeout_ms = 1500000' '$W/config.toml'"
chk "T2 保留 [tui]/[projects]" "grep -q 'status_line' '$W/config.toml' && grep -q 'trust_level' '$W/config.toml'"
chk "T2 default.toml 已建" "[ -f '$W/agents/default.toml' ]"
chk "T2 子模型正确" "grep -q 'model = \"gpt-6-sol\"' '$W/agents/default.toml'"
chk "T2 子模型档位正确" "grep -q 'model_reasoning_effort = \"medium\"' '$W/agents/default.toml'"
chk "T2 verify 通过" "$PY '$LIB' verify --codex-home '$W' >/dev/null"
chk "T2 报告 AGENTS.md 被跳过" "grep -q 'no-agents-md' '$OUT/last.out'"

echo; echo "══ T3 幂等"
inst "$W"
ADD=$(grep -c '^  + ' "$OUT/last.out" || true); MOD=$(grep -c '^  ~ ' "$OUT/last.out" || true)
chk "T3 无新增" "[ ${ADD:-9} -eq 0 ]"
chk "T3 无修改" "[ ${MOD:-9} -eq 0 ]"
chk "T3 无改动时不建备份" "grep -q '已是期望状态' '$OUT/last.out'"

echo; echo "══ T8 输入容错与参数校验"
W8="$OUT/t8"; rm -rf "$W8"; mkdir -p "$W8"
inst "$W8" --root-model gpt-5.6-sol --root-effort medium --sub-model gpt-5.6-terra --sub-effort high --wait-minutes 20
chk "T8 root model" "grep -q '^model = \"gpt-5.6-sol\"' '$W8/config.toml'"
chk "T8 root effort" "grep -q '^model_reasoning_effort = \"medium\"' '$W8/config.toml'"
chk "T8 sub model" "grep -q 'model = \"gpt-5.6-terra\"' '$W8/agents/default.toml'"
chk "T8 sub effort" "grep -q 'model_reasoning_effort = \"high\"' '$W8/agents/default.toml'"
chk "T8 20 分钟 = 1200000" "grep -q 'default_wait_timeout_ms = 1200000' '$W8/config.toml'"
chk "T8 TOML 仍合法" "$PY -c 'import tomllib;tomllib.loads(open(\"$W8/config.toml\").read())'"
W8B="$OUT/t8b"; rm -rf "$W8B"; mkdir -p "$W8B"
inst "$W8B" --root-model '"gpt-5.6-sol"' --sub-model "'gpt-5.6-terra'"
chk "T8b 容忍带引号的模型名" "grep -q '^model = \"gpt-5.6-sol\"' '$W8B/config.toml'"
chk "T8b 容忍单引号子模型" "grep -q 'model = \"gpt-5.6-terra\"' '$W8B/agents/default.toml'"
W8C="$OUT/t8c"; rm -rf "$W8C"; mkdir -p "$W8C"
inst "$W8C" --root-effort bogus; rc=$?
chk "T8c 非法档位被拒绝" "[ $rc -ne 0 ]"
chk "T8c 提示可选值" "grep -q '取值非法' '$OUT/last.out'"
inst "$W8C" --wait-minutes 90; rc=$?
chk "T8d 超过 60 分钟被拒绝" "[ $rc -ne 0 ]"

echo; echo "══ T4 回滚（字节级还原 + 删除新建文件）"
uninst "$W"; rc=$?
chk "T4 exit 0" "[ $rc -eq 0 ]"
chk "T4 config 逐字节还原" "[ \"$(sha "$W/config.toml")\" = \"$B\" ]"
chk "T4 新建的 default.toml 被删除" "[ ! -e \"$W/agents/default.toml\" ]"
chk "T4 有汇总" "grep -q '汇总' '$OUT/last_un.out'"

echo; echo "══ T5 空环境：安装后回滚应恢复为空"
W5="$OUT/t5"; rm -rf "$W5"; mkdir -p "$W5"
inst "$W5"
chk "T5 config 新建成功" "[ -f '$W5/config.toml' ]"
chk "T5 参数生效" "grep -q '^model = \"gpt-6-astra\"' '$W5/config.toml'"
N5=$(grep -c '^\[agents\]$' "$W5/config.toml" 2>/dev/null || true)
chk "T5 只有一张 [agents]" "[ ${N5:-0} -eq 1 ]"
uninst "$W5"
chk "T5 config 被删除" "[ ! -e '$W5/config.toml' ]"
chk "T5 agents 目录已清理" "[ ! -e '$W5/agents' ]"

echo; echo "══ T6 漂移保护"
W6="$OUT/t6"; rm -rf "$W6"; mkdir -p "$W6"; cp "$FIX/config_existing.toml" "$W6/config.toml"
B6=$(sha "$W6/config.toml")
inst "$W6"
echo "# 手工改动" >> "$W6/config.toml"
uninst "$W6"
chk "T6 无 --force 时跳过" "grep -q '跳过' '$OUT/last_un.out'"
chk "T6 文件未被还原" "[ \"$(sha "$W6/config.toml")\" != \"$B6\" ]"
uninst "$W6" --force
chk "T6 --force 后字节级还原" "[ \"$(sha "$W6/config.toml")\" = \"$B6\" ]"

echo; echo "══ T7 project 模式"
P="$OUT/t7"; rm -rf "$P"; mkdir -p "$P"
bash "$REPO/install.sh" -p "$P" -y --no-agents-md > "$OUT/last.out" 2>&1; rc=$?
chk "T7 exit 0" "[ $rc -eq 0 ]"
chk "T7 写入 .codex/config.toml" "[ -f '$P/.codex/config.toml' ]"
chk "T7 写入 .codex/agents/default.toml" "[ -f '$P/.codex/agents/default.toml' ]"
chk "T7 备份在项目内" "[ -d '$P/.codex/backups' ]"
bash "$REPO/uninstall.sh" -p "$P" > "$OUT/last_un.out" 2>&1
chk "T7 回滚后清理" "[ ! -e '$P/.codex/config.toml' ] && [ ! -e '$P/.codex/agents' ]"

echo; printf '%.0s─' {1..64}; echo
printf '结果：%d 通过，%d 失败\n' "$pass" "$fail"
exit $(( fail > 0 ))
