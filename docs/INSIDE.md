# INSIDE：每一项配置为什么这么设

依据分三类，正文里标出：**实测**（本机真机 spawn + 读 rollout）、**源码**（openai/codex 对应版本读函数体）、**社区**（多人复现的公开报告）。
环境基准：`codex-cli 0.154.0`，root `gpt-6-astra`。

---

## config.toml

### `model` / `model_reasoning_effort`（根代理）

根线程是编排会话里最大的一笔开销——它全程存活、每次响应都重读自己的上下文。一个第三方实测样本里，Astra 根线程占掉了整场会话约一半用量，却只产出 6.9k 输出 token（社区）。
所以根代理的档位比任何子代理设置都更决定账单：`low` 是社区公认"复杂任务仍够用"的起点。

注意：这两个键**必须在文件的第一个 `[table]` 之前**，否则会被解析进最后一张表里。工具会自动放在顶部。

### `[agents] enabled = true`

多代理工具的总开关。关掉它（`false`）就是"完全不派子代理"的对照模式，也是排查"到底是谁在烧钱"的第一刀。

### 刻意**不**设 `[agents] max_concurrent_threads_per_session`

- 源码：V2 实际槽位 = 该值 **+1**，而 V2 默认的 4 已经**含根代理**（实测提示文案："There are 4 available concurrency slots … including you"）。
- 也就是说写 4 会得到 5 个线程。每个并发子代理都在每轮重读自己的整份上下文，所以这个数字只会往上花钱。
- 结论：留空，用默认。

### 刻意**不**设 `[agents] default_subagent_model`

- 实测：`agents/default.toml` 里的 `model` 优先于这个键。两者同时存在时本键被**静默忽略**。
- 与其留一个"改了没反应"的坑，不如只保留一处真相。工具检测到它已存在时会明确告警。

### `[features.multi_agent_v2] min/default/max_wait_timeout_ms`

- 默认值是 `10000 / 30000 / 3600000`（源码）。那个 **30000（30 秒）** 就是"Astra 烧额度特别快"的主因：父代理每 30 秒醒来一次、问一句"子代理好了吗"，而每次醒来都要重读整份上下文。
- 一份带遥测的公开报告：一次编排里 47 次轮询**全部**是空轮询，却占掉父线程 **68%** 的输入（约 713 万 token），5 小时额度 33 分钟内从 53% 冲到 100%；每次空轮询约 15 万输入 token。
- 取 **25 分钟**的理由：GPT-5.6 起提示缓存的保留下限是 **30 分钟**（官方文档：`prompt_cache_options.ttl` 目前只支持 `"30m"`，含义是"最近一次写入**或复用**之后至少 30 分钟"）。25 分钟既消掉空轮询，又保证下次醒来时那十几万 token 仍命中缓存；睡过 30 分钟反而变成全价未压缩输入（且 GPT-5.6 起**缓存写入本身**也要按 1.25× 未缓存输入价计费）。
- 三个值必须同时设：只设一个会回落到 30 秒。约束：`min <= default <= max`，范围 `[0, 3600000]`（源码，写反了 Codex 会拒绝启动）。

### `[features.multi_agent_v2] expose_spawn_agent_model_overrides` —— 默认**不写**（保留升级余地）

- 实测（A/B 真机对照）：默认 `true` 时父代理能填 `model` / `reasoning_effort`；设成 `false` 时它的调用里只剩 `task_name` / `fork_turns` / `agent_type`，子代理的模型与档位**只能**来自角色文件。
- 本工具默认**不写这个键**，即保留 `true`：需要时父代理（或你）可以显式把某个子代理升到更强 / 更贵的模型，例如疑难 bug、跨系统设计这类任务。
- "默认不烧 Astra" 由 `agents/default.toml` 的钉位负责（泛型派生一律走它的 `model` / `model_reasoning_effort`，默认 `gpt-5.6-sol` / `medium`），"需要时才升级"由显式调用负责。二者分工明确，互不冲突。
- 想彻底钉死（父代理无权升级），手动加一行 `expose_spawn_agent_model_overrides = false`。
- **版本注意**：该键自 `codex-cli 0.147` 起才存在。本表带 `deny_unknown_fields`，把它写到更早的版本上会让**整份 config 加载失败**（报 `data did not match any variant of untagged enum FeatureToml`）。等待三件套自 0.140 起就有。

### 刻意**不**设 `hide_spawn_agent_metadata`

常见误解是"默认 `true` 会让角色选不中"。**在 0.150+ 已经不成立。**

- 版本边界（源码逐 tag 读 `create_spawn_agent_tool_v2` 函数体）：
  - `0.144.0`：`hide=true` 会删掉 `agent_type` + `model` + `reasoning_effort`
  - `0.150.0`：改为 `agent_type` 由"是否存在角色文件"决定，`hide` 只删 `service_tier`
  - `0.153.4+`：V2 里 `hide` **不删任何参数**，那个删除函数只剩 V1 分支在用
- 实测（0.154.0 A/B）：`hide` 取 `true` / `false`，角色**都被正常选中**。
- 它在 V2 只剩三个副作用：spawn 返回值是否带 nickname（`true` 只回 `task_name`）、output schema 形态、以及是否注入那句"整份 fork 会继承父模型"的提示。
- 想按名字选角色，条件只有一个：**存在角色文件**。

---

## AGENTS.md

装在 `$CODEX_HOME/AGENTS.md`（global）或 `<repo>/AGENTS.md`（project），内容放在 `BEGIN/END astra-diet` 受管区块里，卸载时整块移除、不伤你原有内容。

为什么是这几条：

- **派发门槛（输入/范围/交付物/停止条件）** —— 三个独立来源指向同一条结论：编排最大的浪费不是模型选错，而是**过度派发**。一个真实项目反馈原话是"委派变得太急切，简单任务膨胀成 explorer→worker→tester/reviewer 循环"，作者随后把流程改成自适应路由（社区）。
- **派发后立刻等待、不重复它的调查** —— 直接消掉上面那 68% 的空转；父代理醒来后自己又读一遍仓库，等于同一份工作做两遍、还把子代理结果丢掉。
- **`fork_turns = "none"`** —— 源码里 `fork_turns` 的官方说明写着 **"Defaults to `all`"**：不传就是把父线程**整份历史**复制给子代理。代价是三重：成本（每个子代理重新 prefill 一大段无关历史）、速度（首轮更慢）、独立性（子代理继承父代理的假设，独立核验退化成找证据）。
- **子代理返回要短** —— 子代理的输出进入 root 上下文后，会被 root **之后每一轮**重读。贴回去的原始日志是永久污染。
- **文件本身要短** —— 系统级 `AGENTS.md` 每轮都注入（上限 32 KiB）。少一句就少付每一轮的钱，也少分散一点注意力。

---

## agents/default.toml

装在 `$CODEX_HOME/agents/default.toml`（global）或 `<repo>/.codex/agents/default.toml`（project）。

- **名字必须是 `default`。** 不传 `agent_type` 的泛型派生会解析成内置角色 `default`，这是唯一会被自动加载的角色名。其它名字必须显式传 `agent_type` 才生效。
- **`model` / `model_reasoning_effort`** —— 钉死子代理的成本，默认 `gpt-5.6-sol` / `medium`。
  - 档位取 `medium` 而非 `max`：社区一致反馈子代理开 `max` 会过度设计、明显变慢；而一个带遥测的实测样本显示推理 token 在总量里占比极小，调档主要影响**墙钟时间**，不是 token 成本。真正决定账单的是"要不要返工"。
  - 模型默认用 Sol 而非更便宜的 Luna：按公开价，Sol 约 $4 / $20（每百万输入 / 输出 token），Astra 约 $10 / $50，而 Luna 约 $0.20 / $1.20 —— Sol 比 Astra 便宜一个量级、比 Luna 贵约 20 倍。选 Sol 是拿单价换"一次做对"的概率，因为子代理返工一次的代价远大于这点单价差。想更省：`--sub-model gpt-5.6-luna`。
- **`sandbox_mode = "read-only"`** —— 探索交给子代理，改动与最终验收留在主代理。只读同时限制了它跑偏的破坏半径。
- **`developer_instructions`** —— 把"只读、单轮、不派生"和返回格式写进角色本身，而不是指望每次派发时都交代一遍。

**不配这个文件会怎样（实测）**：泛型派生的子代理**继承父代理的模型与档位**——也就是"Astra 派一堆 Astra"。这是当前最常见的隐性开销，而不是什么 `hide_spawn_agent_metadata` 的锅。

---

## 一句话的优先级链（实测）

`spawn_agent` 显式传的 `model` > 角色文件里的 `model` > `[agents] default_subagent_model` > 继承父代理。
