# astra-diet

把 Codex 的**默认模型、子代理钉位、等待行为**合并进配置，减少被浪费的用量。
安装 = 三处写入 + 一次备份；卸载 = 按备份精确回滚。

## 装什么

| 目标（global 模式） | 内容 |
|---|---|
| `$CODEX_HOME/config.toml` | 根代理模型与档位、`[agents]`、`[features.multi_agent_v2]` 等待与路由开关 |
| `$CODEX_HOME/AGENTS.md` | 子代理使用纪律（受管区块，前后有 `BEGIN/END astra-diet` 标记） |
| `$CODEX_HOME/agents/default.toml` | 泛型子代理的角色文件：模型、档位、只读、返回格式 |

project 模式把同样三份写到 `<dir>/.codex/config.toml`、`<dir>/AGENTS.md`、`<dir>/.codex/agents/default.toml`。

**每一项为什么这么设、依据是什么 → [`docs/INSIDE.md`](docs/INSIDE.md)。**

## 用法

```bash
./install.sh -n            # 先看会发生什么（不写文件）
./install.sh               # 交互式：选模式、填模型与档位
./install.sh -y            # 非交互，全部用默认值
./install.sh -p ~/repo     # 装进某个项目（project 模式）
./install.sh --verify      # 校验已装内容是否与清单一致

./uninstall.sh -n          # 先看回滚会做什么
./uninstall.sh             # 回滚（默认取最新备份）
./uninstall.sh --force     # 安装后你又手工改过文件时，强行回滚（先自己备份）
```

常用参数：`--root-model` `--root-effort` `--sub-model` `--sub-effort` `--wait-minutes` `--no-agents-md` `--codex-home`。
`--help` 看全部。

## 行为约定

- **合并而非覆盖。** 逐键写入，用户原有的注释、键顺序、未涉及的段落逐字节保留。
- **每次改动前备份**，并写下 `backups/astra-diet-<时间戳>/manifest.json`（含改动前后的 sha256）。
- **打印变更摘要**：`+` 新增　`~` 修改（旧值 → 新值）　`=` 未变　`!` 提醒，附精简 unified diff。
- **幂等。** 重复安装只比较值，同值报 `=`，不堆叠注释。
- **危险动作前有闸门。** 回滚时若发现文件在安装后被改动过，默认跳过并提示，需 `--force`。
- **不碰清单之外的东西。** 不删备份、不改 `.gitignore`、不动 MCP/plugins/notify/model_provider。

## 前提与局限

- 需要 `codex-cli >= 0.150`（`[features.multi_agent_v2]` 与角色路由语义在该版本后稳定）。install 会检查并提醒。
- project 模式的 `.codex/config.toml` 只对**受信任项目**生效，首次进入需在 Codex 里确认信任。
- 本工具只写配置，不验证效果。要确认子代理真的落到你钉的模型：开一个**新会话**让它派生一个子代理，
  然后读 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` —— 子代理线程首行的
  `session_meta.source.subagent.thread_spawn.agent_role` 应为 `default`，其最后一条 `turn_context.model`
  应为角色文件里钉的模型（而不是父代理的模型）。

## 目录

```
payload/   config.toml.tmpl  AGENTS.md.tmpl  default.toml.tmpl   ← 三份模板都带 .tmpl 后缀
lib/       astra_diet.py     ← 合并/回滚/校验的唯一实现
tests/     selftest.sh  fixtures/                                ← 自测（53 项）
docs/      INSIDE.md         ← 每个配置项的作用与实测依据
```

模板带 `.tmpl` 后缀是刻意的：放在仓库里的 `AGENTS.md` 会被在这个仓库里工作的 coding agent 当成自己的指令读进去，
加后缀就不会被误认。

## 自测

```bash
bash tests/selftest.sh     # 53 项，全部在 /tmp 沙箱里跑，不碰真实 ~/.codex
```

覆盖：合并进既有 config（保留未知键、不产生重复表）、幂等、dry-run 不落盘、回滚字节级还原、
漂移保护、project 模式、模型名带引号的容错、非法档位/超范围等待值被拒。

**已验证到生产环境**（2026-09-10，全局安装后实测）：安装只给 `config.toml` 增加了受管区块（20 行 diff），
用户原有的 38 个 `[projects.*]`、MCP、plugins、`[desktop]`、`[tui]` 全部原样；泛型派生的子代理从
"继承 Astra" 变成 `role=default / gpt-5.6-luna / medium`，且 `spawn_agent` 参数里不再出现 `model` /
`reasoning_effort`（`expose_spawn_agent_model_overrides = false` 生效）。

**仍未覆盖**：`AGENTS.md` 的"追加到已有用户内容"分支（安装时该文件不存在，走的是新建分支）；
真实卸载只验过 dry-run 与沙箱。
