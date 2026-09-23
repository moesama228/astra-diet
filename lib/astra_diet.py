#!/usr/bin/env python3
"""astra-diet 核心：外科手术式合并写入 / 回滚 / 校验。

设计原则
--------
1. **只做文本级外科手术**，绝不整文件重写：用户原有的注释、键顺序、以及未涉及的
   段落逐字节保留。因此不用 toml 库做 round-trip（那会重排并丢掉注释）。
2. **可精确回滚**：改动前把原文件复制进备份目录，并在 manifest.json 里记下
   改动前后 sha256。回滚 = 写回备份 / 删除新建文件；不依赖对文本的逆向操作。
3. **幂等**：重复安装只做值比较，同值报 `=`，不堆叠注释。
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

try:                       # Python 3.11+
    import tomllib
except ModuleNotFoundError:  # older interpreters: try the backport
    try:
        import tomli as tomllib
    except ModuleNotFoundError:
        tomllib = None

BLOCK_BEGIN = "BEGIN astra-diet"
BLOCK_END = "END astra-diet"
MARKERS = {
    "toml": (f"# {BLOCK_BEGIN}", f"# {BLOCK_END}"),
    "md": (f"<!-- {BLOCK_BEGIN} -->", f"<!-- {BLOCK_END} -->"),
}

ROOT_COMMENTS = {
    "model": "# astra-diet: 根代理模型。子代理模型见 agents/default.toml",
    "model_reasoning_effort": "# astra-diet: 根代理推理档位；档位越高思考 token 越多",
}

SECTION_COMMENTS = {
    ("agents", "enabled"): "# astra-diet: 多代理工具开关",
    ("features.multi_agent_v2", "min_wait_timeout_ms"): "# astra-diet: 父代理等待子代理的上限；默认 30 秒会让它反复醒来重读上下文",
    ("features.multi_agent_v2", "default_wait_timeout_ms"): "# astra-diet: 同上，缺省等待时长",
    ("features.multi_agent_v2", "max_wait_timeout_ms"): "# astra-diet: 同上，允许请求的最长等待（须 >= default）",
    ("features.multi_agent_v2", "expose_spawn_agent_model_overrides"): "# astra-diet: 关掉后父代理无法挑选子代理模型/档位，一律走角色文件",
}

_TABLE_RE = re.compile(r"^\[(?P<name>[^\[\]\n]+)\][ \t]*$", re.M)


# ---------------------------------------------------------------- helpers
def sha256(path: Path) -> str | None:
    if not path.exists():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def root_end(text: str) -> int:
    m = _TABLE_RE.search(text)
    return m.start() if m else len(text)


def section_span(text: str, table: str):
    """Span of `[table]` through the line before the next table header."""
    header = re.search(rf"^\[{re.escape(table)}\][ \t]*$", text, re.M)
    if not header:
        return None
    nxt = _TABLE_RE.search(text[header.end():])
    end = header.end() + nxt.start() if nxt else len(text)
    return header.start(), end


def block_span(text: str, kind: str):
    begin, end = MARKERS[kind]
    i = text.find(begin)
    if i == -1:
        return None
    j = text.find(end, i)
    if j == -1:
        return None
    return i, j + len(end)


def _line_with_comment(text: str, key: str, value: str, comment: str | None) -> str:
    """Render `key = value`, prefixing the astra-diet comment once."""
    line = f"{key} = {value}"
    if comment and comment not in text:
        return f"{comment}\n{line}"
    return line


def set_root_scalar(text: str, key: str, value: str) -> tuple[str, str, str]:
    """Return (text, op, detail). op in {add, mod, same}."""
    comment = ROOT_COMMENTS.get(key)
    pattern = re.compile(rf"^{re.escape(key)}[ \t]*=.*$", re.M)
    m = pattern.search(text[: root_end(text)])
    new_line = _line_with_comment(text, key, value, comment)
    if m:
        old_value = m.group(0).split("=", 1)[1].strip()
        if old_value == value:
            return text, "same", f"{key} = {value}"
        out = text[: m.start()] + new_line + text[m.end():]
        return out, "mod", f"{key}: {old_value}  ->  {value}"
    if not text.strip():
        return new_line + "\n", "add", f"{key} = {value}（新建文件）"
    return new_line + "\n" + text, "add", f"{key} = {value}（此前未设置）"


def set_section_key(text: str, table: str, key: str, value: str) -> tuple[str, str, str]:
    """Set/replace `key` inside existing `[table]`; caller guarantees the table exists."""
    span = section_span(text, table)
    assert span
    start, end = span
    body = text[start:end]
    pattern = re.compile(rf"^{re.escape(key)}[ \t]*=.*$", re.M)
    m = pattern.search(body)
    comment = SECTION_COMMENTS.get((table, key))
    line = _line_with_comment(body, key, value, comment)
    if m:
        old_value = m.group(0).split("=", 1)[1].strip()
        if old_value == value:
            return text, "same", f"[{table}] {key} = {value}"
        new_body = body[: m.start()] + line + body[m.end():]
        return text[:start] + new_body + text[end:], "mod", f"[{table}] {key}: {old_value}  ->  {value}"
    new_body = body if body.endswith("\n") else body + "\n"
    new_body = new_body + line + "\n"
    return text[:start] + new_body + text[end:], "add", f"[{table}] {key} = {value}"


# ---------------------------------------------------------------- plan/apply
def plan_config(existing: str, *, root_model, root_effort, wait_ms, block: str):
    """Return (new_text, changes[list[dict]])."""
    changes = []
    text = existing
    # 逆序插入：缺失的顶层键是逐个前插的，倒过来迭代才能让 model 落在最前面。
    for key, value in (("model_reasoning_effort", f'"{root_effort}"'),
                       ("model", f'"{root_model}"')):
        text, op, detail = set_root_scalar(text, key, value)
        changes.append({"op": op, "detail": detail})
    changes.reverse()

    if "[agents]" in text:
        text, op, detail = set_section_key(text, "agents", "enabled", "true")
        changes.append({"op": op, "detail": detail})
    if "[features.multi_agent_v2]" in text:
        for key, value in (("min_wait_timeout_ms", str(wait_ms)),
                           ("default_wait_timeout_ms", str(wait_ms)),
                           ("max_wait_timeout_ms", str(wait_ms)),
                           ("expose_spawn_agent_model_overrides", "false")):
            text, op, detail = set_section_key(text, "features.multi_agent_v2", key, value)
            changes.append({"op": op, "detail": detail})
    kept = keep_missing_tables(block, existing)
    if kept:
        if block_span(text, "toml"):
            i, j = block_span(text, "toml")
            text = text[:i] + kept.strip() + text[j:]
            changes.append({"op": "mod", "detail": f"更新受管区块（{BLOCK_BEGIN}）"})
        else:
            joiner = "" if not text else ("\n" if text.endswith("\n\n") else "\n\n" if text.endswith("\n") else "\n\n")
            text = text + joiner + kept.strip() + "\n"
            added = [ln for ln in kept.splitlines() if _TABLE_RE.match(ln.strip())]
            changes.append({"op": "add", "detail": f"追加受管区块（{BLOCK_BEGIN}），含 {'、'.join(added)}"})
    return text, changes


def plan_agents_md(existing: str, block: str, source: str):
    changes = []
    if not existing.strip():
        return block.strip() + "\n", [{"op": "add", "detail": "新建文件，写入受管区块"}]
    span = block_span(existing, "md")
    if span:
        i, j = span
        new = existing[:i] + block.strip() + existing[j:]
        op = "same" if new == existing else "mod"
        changes.append({"op": op, "detail": f"更新受管区块（{BLOCK_BEGIN} / {BLOCK_END}）"})
        return new, changes
    new = existing.rstrip("\n") + "\n\n" + block.strip() + "\n"
    changes.append({"op": "add", "detail": "追加受管区块，原有内容逐字保留"})
    return new, changes


def plan_role_file(existing: str, *, sub_model, sub_effort, template: str):
    """Merge into an existing role file, or write the template verbatim."""
    if not existing.strip():
        body = (template.replace("{{SUB_MODEL}}", sub_model)
                        .replace("{{SUB_EFFORT}}", sub_effort))
        return body, [{"op": "add", "detail": "新建文件（name=default 的泛型子代理）"}]
    changes = []
    text = existing
    for key, value in (("name", '"default"'),
                       ("model", f'"{sub_model}"'),
                       ("model_reasoning_effort", f'"{sub_effort}"')):
        pattern = re.compile(rf"^{re.escape(key)}[ \t]*=.*$", re.M)
        m = pattern.search(text)
        if m:
            old_value = m.group(0).split("=", 1)[1].strip()
            if old_value == value:
                changes.append({"op": "same", "detail": f"{key} = {value}"})
                continue
            text = text[: m.start()] + f"{key} = {value}" + text[m.end():]
            changes.append({"op": "mod", "detail": f"{key}: {old_value}  ->  {value}"})
        else:
            text = text.rstrip("\n") + f"\n{key} = {value}\n"
            changes.append({"op": "add", "detail": f"{key} = {value}"})
    for key in ("sandbox_mode", "developer_instructions"):
        if re.search(rf"^{re.escape(key)}[ \t]*=", text, re.M):
            changes.append({"op": "same", "detail": f"{key} 已存在，保留原值"})
        else:
            changes.append({"op": "warn", "detail": f"{key} 缺失：现有角色文件未设置，请自行确认（工具不改动它）"})
    return text, changes


def keep_missing_tables(block: str, existing: str):
    """Drop table sections from the managed block whose header already exists in the
    target file, so we never emit a duplicate table (invalid TOML). Returns None if
    nothing is left to add."""
    lines = block.splitlines()
    begin, end = MARKERS["toml"]
    head = []
    i = 0
    while i < len(lines) and not lines[i].lstrip().startswith("["):
        head.append(lines[i]); i += 1
    sections, cur = [], None
    for ln in lines[i:]:
        if ln.strip() == end:
            break
        if _TABLE_RE.match(ln.strip()):
            if cur:
                sections.append(cur)
            cur = [ln]
        elif cur is not None:
            cur.append(ln)
    if cur:
        sections.append(cur)
    kept = []
    for sec in sections:
        name = _TABLE_RE.match(sec[0].strip()).group("name")
        if f"[{name}]" not in existing:
            kept.append(sec)
    if not kept:
        return None
    out = list(head)
    for sec in kept:
        while out and out[-1].strip() == "":
            out.pop()
        out.append("")
        out.extend(sec)
    while out and out[-1].strip() == "":
        out.pop()
    out.append(end)
    return "\n".join(out) + "\n"


def unified_diff(before: str, after: str, label: str, limit: int = 40) -> str:
    lines = list(difflib.unified_diff(before.splitlines(), after.splitlines(),
                                      fromfile=f"a/{label}", tofile=f"b/{label}",
                                      lineterm="", n=2))
    if not lines:
        return ""
    if len(lines) > limit:
        lines = lines[:limit] + [f"... （diff 共 {len(lines)} 行，已截断）"]
    return "\n".join(lines)


SYMBOL = {"add": "+", "mod": "~", "same": "=", "warn": "!"}


def render_changes(path: Path, label: str, changes, diff: str) -> str:
    out = [f"\n{label}  ({path})"]
    for c in changes:
        out.append(f"  {SYMBOL[c['op']]} {c['detail']}")
    if diff:
        out.append("  --- diff ---")
        out.extend("  " + ln for ln in diff.splitlines())
    return "\n".join(out)


# ---------------------------------------------------------------- entry points
def _unquote(v: str) -> str:
    """Tolerate values pasted from a TOML snippet, e.g. --sub-model '"gpt-6-sol"'."""
    v = (v or "").strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def cmd_apply(a) -> int:
    EFFORTS = {"minimal", "low", "medium", "high", "xhigh", "max"}
    a.root_model, a.root_effort = _unquote(a.root_model), _unquote(a.root_effort)
    a.sub_model, a.sub_effort = _unquote(a.sub_model), _unquote(a.sub_effort)
    for flag, val in (("--root-effort", a.root_effort), ("--sub-effort", a.sub_effort)):
        if val not in EFFORTS:
            raise SystemExit(f"{flag} 取值非法：{val!r}（可选：{'/'.join(sorted(EFFORTS))}）")
    for flag, val in (("--root-model", a.root_model), ("--sub-model", a.sub_model)):
        if not val:
            raise SystemExit(f"{flag} 不能为空")
    if not 0 < a.wait_minutes <= 60:
        raise SystemExit("--wait-minutes 必须在 0 到 60 之间（Codex 的硬上限是 3600000ms）")

    repo = Path(a.repo).resolve()
    payload = repo / "payload"
    if a.mode == "global":
        codex_home = Path(a.codex_home).expanduser()
        agents_md = codex_home / "AGENTS.md"
    else:
        project = Path(a.project).expanduser().resolve()
        codex_home = project / ".codex"
        agents_md = project / "AGENTS.md"

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = codex_home / "backups" / f"astra-diet-{stamp}"
    wait_ms = int(round(a.wait_minutes * 60_000))
    block = (payload / "config.toml.tmpl").read_text(encoding="utf-8").replace("{{WAIT_MS}}", str(wait_ms))
    md_block = (payload / "AGENTS.md.tmpl").read_text(encoding="utf-8")
    role_tpl = (payload / "default.toml.tmpl").read_text(encoding="utf-8")

    targets = [
        ("config.toml", codex_home / "config.toml", "toml"),
        ("AGENTS.md", agents_md, "md"),
        ("agents/default.toml", codex_home / "agents" / "default.toml", "toml"),
    ]

    plan = []
    for label, path, kind in targets:
        if label == "AGENTS.md" and a.no_agents_md:
            plan.append({"label": label, "path": path, "skip": True, "changes": [], "new": None, "diff": "", "before": ""})
            continue
        before = read(path)
        if label == "config.toml":
            new, changes = plan_config(before, root_model=a.root_model, root_effort=a.root_effort,
                                       wait_ms=wait_ms, block=block)
        elif label == "AGENTS.md":
            new, changes = plan_agents_md(before, md_block, "global")
        else:
            new, changes = plan_role_file(before, sub_model=a.sub_model, sub_effort=a.sub_effort,
                                         template=role_tpl)
        plan.append({"label": label, "path": path, "skip": False, "changes": changes,
                     "new": new, "before": before,
                     "diff": "" if not before.strip() else unified_diff(before, new, label)})

    # 冲突检查：config 里同时存在 default_subagent_model
    cfg_before = read(codex_home / "config.toml")
    if re.search(r"^[ \t]*default_subagent_model[ \t]*=", cfg_before, re.M):
        for p in plan:
            if p["label"] == "config.toml":
                p["changes"].append({"op": "warn", "detail":
                    "[agents] default_subagent_model 已存在：与 agents/default.toml 同时存在时以文件为准，"
                    "该键会被静默忽略（可考虑删除以避免误判）"})

    # 真正写入
    manifest = {"tool": "astra-diet", "stamp": stamp, "mode": a.mode,
                "codex_home": str(codex_home), "backup_dir": str(backup),
                "entries": []}
    for p in plan:
        if p["skip"]:
            print(f"\n{p['label']}  ({p['path']})\n  ! --no-agents-md：按要求跳过")
            continue
        print(render_changes(p["path"], p["label"], p["changes"], p["diff"]))
        entry = {"target": str(p["path"]), "label": p["label"],
                 "sha_before": sha256(p["path"]), "action": "unchanged", "backup_file": None}
        changed = p["before"] != p["new"]
        if changed:
            entry["action"] = "modified" if p["path"].exists() else "created"
            if not a.dry_run:
                p["path"].parent.mkdir(parents=True, exist_ok=True)
                if entry["action"] == "modified":
                    backup.mkdir(parents=True, exist_ok=True)
                    rel = f"{p['label'].replace('/', '__')}.bak"
                    shutil.copy2(p["path"], backup / rel)
                    entry["backup_file"] = rel
                p["path"].write_text(p["new"], encoding="utf-8")
        entry["sha_after"] = sha256(p["path"]) if not a.dry_run else None
        manifest["entries"].append(entry)

    if a.dry_run:
        print("\n[dry-run] 未写入任何文件。上面的 +/~/= 就是将要发生的变化。")
        return 0

    if not any(e["action"] != "unchanged" for e in manifest["entries"]):
        print("\n所有目标已是期望状态，未改动文件，也未新建备份目录。")
        return 0

    backup.mkdir(parents=True, exist_ok=True)
    (backup / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                                          encoding="utf-8")
    print(f"\n备份与清单：{backup}/manifest.json")
    # 立即自校验：保证写入结果可被解析
    if tomllib is None:
        print("TOML 校验：跳过（当前 python 既没有 tomllib 也没有 tomli；建议用 3.11+ 运行）")
        return 0
    for p in plan:
        if p["skip"] or p["path"].suffix != ".toml":
            continue
        try:
            tomllib.loads(read(p["path"]))
        except Exception as exc:  # pragma: no cover
            print(f"  ! {p['path']} TOML 解析失败：{exc}")
            return 1
    print("TOML 校验：通过")
    return 0


def _load_manifest(backup: Path) -> dict:
    mf = backup / "manifest.json"
    if not mf.exists():
        raise SystemExit(f"找不到清单：{mf}")
    return json.loads(mf.read_text(encoding="utf-8"))


def _pick_backup(base: Path) -> Path:
    """Newest backup whose manifest actually recorded a change.

    A repeat install that found everything already in place writes no backup, and an
    older install may legitimately be 'unchanged'-only; skip those so that uninstall
    finds the manifest that can really restore something.
    """
    cands = sorted(p for p in base.glob("astra-diet-*") if (p / "manifest.json").exists())
    if not cands:
        raise SystemExit(f"没有找到任何备份目录（{base}/astra-diet-*）")
    for b in reversed(cands):
        try:
            man = json.loads((b / "manifest.json").read_text(encoding="utf-8"))
        except Exception:
            continue
        if any(e.get("action") != "unchanged" for e in man.get("entries", [])):
            return b
    return cands[-1]


def cmd_revert(a) -> int:
    if a.backup:
        backup = Path(a.backup).expanduser()
    else:
        backup = _pick_backup(Path(a.codex_home).expanduser() / "backups")
    man = _load_manifest(backup)
    print(f"使用备份：{backup}")
    restored = deleted = skipped = 0
    for e in man["entries"]:
        target = Path(e["target"])
        cur = sha256(target)
        if e["action"] == "unchanged":
            continue
        drift = cur != e.get("sha_after")
        if drift and not a.force:
            print(f"  ! 跳过 {target}：安装后被改动过（先自行备份，再用 --force 覆盖）")
            skipped += 1
            continue
        if e["action"] == "created":
            if target.exists():
                if a.dry_run:
                    print(f"  - [dry-run] 将删除 {target}")
                else:
                    target.unlink()
                    print(f"  - 已删除 {target}")
                deleted += 1
        else:
            src = backup / e["backup_file"]
            if not src.exists():
                print(f"  ! 跳过 {target}：找不到备份文件 {src}")
                skipped += 1
                continue
            if a.dry_run:
                print(f"  ~ [dry-run] 将还原 {target}")
            else:
                shutil.copy2(src, target)
                print(f"  ~ 已还原 {target}")
            restored += 1
    for d in (Path(man["codex_home"]) / "agents",):
        if not a.dry_run and d.is_dir() and not any(d.iterdir()):
            d.rmdir()
            print(f"  - 已删除空目录 {d}")
    print(f"\n汇总：还原 {restored}，删除 {deleted}，跳过 {skipped}" +
          ("（dry-run，未改动任何文件）" if a.dry_run else ""))
    if not a.dry_run:
        print(f"备份存档已保留（这是还原点，不是安装包）：{backup}")
        print(f"  指定用它回滚：uninstall.sh --backup {backup}")
        print(f"  校验当前状态：uninstall.sh --verify --backup {backup}")
        print("  确认不需要后可直接删除该目录。")
    return 0


def cmd_verify(a) -> int:
    if a.backup:
        backup = Path(a.backup).expanduser()
    else:
        backup = _pick_backup(Path(a.codex_home).expanduser() / "backups")
    man = _load_manifest(backup)
    print(f"依据清单：{backup}/manifest.json")
    bad = 0
    for e in man["entries"]:
        target = Path(e["target"])
        cur = sha256(target)
        if e["action"] == "unchanged":
            state = "未参与（安装时无变化）"
        elif cur is None:
            state = "缺失"; bad += 1
        elif cur == e.get("sha_after"):
            state = "与安装时一致"; 
        else:
            state = "已被改动（drift）"; bad += 1
        print(f"  {e['label']:<22} {state}")
    print("校验：通过" if not bad else f"校验：{bad} 处异常")
    return 1 if bad else 0


def main() -> int:
    p = argparse.ArgumentParser(prog="astra-diet")
    sub = p.add_subparsers(dest="cmd", required=True)

    ap = sub.add_parser("apply")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--mode", choices=["global", "project"], required=True)
    ap.add_argument("--codex-home", required=True)
    ap.add_argument("--project")
    ap.add_argument("--root-model", required=True)
    ap.add_argument("--root-effort", required=True)
    ap.add_argument("--sub-model", required=True)
    ap.add_argument("--sub-effort", required=True)
    ap.add_argument("--wait-minutes", type=float, required=True)
    ap.add_argument("--no-agents-md", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.set_defaults(func=cmd_apply)

    rv = sub.add_parser("revert")
    rv.add_argument("--codex-home", required=True)
    rv.add_argument("--backup")
    rv.add_argument("--dry-run", action="store_true")
    rv.add_argument("--force", action="store_true")
    rv.set_defaults(func=cmd_revert)

    vf = sub.add_parser("verify")
    vf.add_argument("--codex-home", required=True)
    vf.add_argument("--backup")
    vf.set_defaults(func=cmd_verify)

    a = p.parse_args()
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
