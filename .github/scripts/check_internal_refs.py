# 由私有仓库 tools/public_comment_hygiene.py 生成（导出时自动复制）——
# 请勿在本仓库直接修改，改上游源。用法：python3 check_internal_refs.py . --check
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""公开树内部引用清洗器（public-trust-1，ADR 0085，2026-11-10）。

背景：公开导出树按既定政策须剥注释里的内部编号引用（ADR 码 / 审查车道码 /
工单号 / 票号——2026-11-05 拍板"剥 ADR/审计码/票号"），但 v1.0.0 首导出
未清洗、v1.0.1 只手工清了增量文件，公开 v1.0.2 树残留 596+ 审查码、175+
工单号、20+ ADR 码（2026-11-10 三路探查实证）。本工具把该政策机械化：
导出管线在 HMS 剥离后自动全树清洗，CI 用 --check 模式拦新增。

清洗边界（安全规则；v1.0.1 手工规则曾因激进正则破坏 YAML——analyze 60 错
事故，教训=只动注释 token、不动缩进与结构）：
  - 只处理注释上下文（// /* */ <!-- --> #），代码与字符串字面量不动；
  - 例外：app/test/**.dart 的测试展示串（group 名/reason）允许清洗——
    无断言依赖，公开树全量测试兜底；
  - 裸单字母+数字码与合法术语歧义——排除集：M2/M3（Material 2/3）、
    K3（Kimi K3 系模型名）、R8（ProGuard/R8）；%XX 百分号编码字节
    （%E4/%C3）负向断言排除；# 十六进制色值按"# 后无空格非注释"排除；
  - 日期叙事与中文注释按 2026-10-28 拍板保留（公开开发常态），不清洗。

用法：
  python tools/public_comment_hygiene.py <导出树根目录>            # 就地清洗+报告
  python tools/public_comment_hygiene.py <目录> --check            # 只检不改，残留退出码 1
  python tools/public_comment_hygiene.py <目录> --report <文件>    # 替换清单落盘

本文件同时是公开库 CI 守卫（.github/scripts/check_internal_refs.py）的
唯一源——stage-public-extras.sh 负责复制，禁止双头维护。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# ---- 扫描范围（按后缀 → 注释语法族）----
SLASH_EXT = {".dart", ".kt", ".kts", ".java", ".gradle"}    # // 行注释 + /* */ 块
HASH_EXT = {".yaml", ".yml", ".properties", ".gitignore", ".cfg", ".toml"}
XML_EXT = {".xml", ".html"}

# 裸车道码排除集（与合法术语歧义，见文件头）。
BARE_EXCLUDE = {"M2", "M3", "K3", "R8"}

# 内部参考路径 → 对外可读措辞（中文注释语境；含 / 的路径类规则
# **只在注释模式生效**——字符串里的 '../tools/logs/x.txt' 是路径字面量
# 不是内部叙事，公开树曾把 design_guard_test 的落盘路径洗成 '../'。
REFS_MAP = [
    (re.compile(r"refs/ZCode\b"), "ZCode 官方开源实现"),
    (re.compile(r"refs/snapshot-3162\b"), "官方 3.16.2 源码快照"),
    (re.compile(r"refs/snapshot-3171\b"), "官方 3.17.1 源码快照"),
    (re.compile(r"refs/new-snapshot\b"), "官方最新源码快照"),
    (re.compile(r"refs/app\b"), "官方 app 源码"),
    (re.compile(r"refs/zemote\b"), "zemote 参考仓库"),
    (re.compile(r"refs/paseo\b"), "paseo 参考仓库"),
    (re.compile(r"refs/[A-Za-z0-9_./-]+"), "参考源码快照"),
]

# 词级改写（两种模式都安全）：裸 "ADR" 一词指向内部决策日志——
# "回填此处+ADR 留痕" 这类无编号形态（终审必修 3）。
WORD_MAP = [
    (re.compile(r"\bADR\b(?!\s?\d)"), "决策记录"),
]

# 直接删除的内部产物名（docs/ 前缀形在前，防裸名先匹配留下 "docs/" 残片；
# 仅注释模式——字符串模式删路径字面量风险同上）。
DROP_TOKENS = [
    re.compile(r"tools?/logs/[^\s，。）;；、\"']*"),
    re.compile(r"docs/[a-z0-9.-]*2026-[0-9]{2}-[0-9]{2}[a-z0-9.-]*"),
    re.compile(r"handoff-2026-[0-9a-z-]*"),
    re.compile(r"(?:visual|human-eye)-retro-\d+"),
]

# 编号码族：token 整体删除（顺序敏感——复合形先于裸形）。
# [①-⑳]* 后缀把紧贴 token 的圈号序数一并带走（A6① → 整体删除）；
# 独立的 ①②③ 列举不挂任何模式，永不动。
# 边界用显式 ASCII 类而非 \b——Python 的 \w 含圈号数字（U+2460 系），
# \b 在 "6|①" 处不成立，后缀会静默失配（红绿抓出）。
_L, _R = r"(?<![A-Za-z0-9_])", r"(?![A-Za-z0-9_])"
_C = "[①-⑳]*"
CODE_TOKENS = [
    (re.compile(r"ADR ?\d{3,4}(?:/ ?\d{3,4})*(?::\d+)?"), "ADR 码"),
    (re.compile(r"§\d+(?:[.\-]\d+)*"), "内部文档节号"),
    (re.compile(r"→0\d{3}\b"), "ADR 裸码速记"),
    (re.compile(r"(?<![0-9A-Za-z])/0\d{3}\b"), "ADR 裸码速记"),
    (re.compile(_L + r"[A-R]\d{1,2}-P\d+(?:-\d+)*" + _R + _C), "车道-子项码"),
    (re.compile(_L + r"[A-R]\d{1,2}-\d{1,2}" + _R + _C), "车道-序号码"),
    (re.compile(_L + r"[A-R]-\d{1,2}" + _R + _C), "车道-序号短码"),
    (re.compile(_L + r"P\d{1,2}-\d{1,2}" + _R + _C), "P 车道码"),
    (re.compile(r"(?<![A-Za-z0-9_])VR-\d+[a-z]?(?![A-Za-z0-9])"), "视觉审查票号"),
    (re.compile(r"(?<![A-Za-z0-9_])PF-\d+(?![A-Za-z0-9])"), "缺陷账本票号"),
    (re.compile(_L + r"S\d{2}" + _R + _C), "游览场景码"),
    (re.compile(r"(?<!\d)180\d\d(?!\d)"), "批次工单号"),
]
# 裸字母+数字码（带排除集与 % 负向断言；显式边界已排除 0xC3/A2DP 类）。
BARE_LANE = re.compile(r"(?<![%A-Za-z0-9_])[A-R]\d{1,2}(?![A-Za-z0-9_])" + _C)

# ---- 标点收敛（全角/半角成对，迭代至稳定）----
# 字符串模式下跳过的标点规则下标（改写语义可能损伤数据串）：
# 0=空括号删除（'（…）' 键形态）、2/3=括号内前导标点剥离。其余收敛
# 对数据串无损（空白/重复标点归一）。
STRING_UNSAFE_PUNCT = {0, 1, 2, 3}

PUNCT_CLEANUPS = [
    (re.compile(r"（\s*(?:见|参见|详见|参考|同|按)?\s*）"), ""),
    (re.compile(r"\(\s*(?:see|cf\.?|ref\.?)?\s*\)"), ""),
    (re.compile(r"（\s*[、,，/;；:：]\s*"), "（"),
    (re.compile(r"\(\s*[,/;:]\s*"), "("),
    (re.compile(r"\s*[、,，]\s*）"), "）"),
    (re.compile(r"\s*[,/]\s*\)"), ")"),
    (re.compile(r"（）|\(\)|【\s*】"), ""),
    (re.compile(r"[，,]\s*[，,]"), "，"),
    (re.compile(r"[、]\s*[、]"), "、"),
    (re.compile(r"（\s*/\s*）"), ""),
    (re.compile(r"（\s*（"), "（"),
    (re.compile(r"）\s*）"), "）"),
    (re.compile(r"（[ \t]+"), "（"),
    (re.compile(r"\s+）"), "）"),
    (re.compile(r"\s+\)"), ")"),
    (re.compile(r"\s+，"), "，"),
    (re.compile(r"\s+。"), "。"),
    (re.compile(r"\s+；"), "；"),
    (re.compile(r"[ \t]{2,}"), " "),
    (re.compile(r"[ \t]+$"), ""),
]

# 整行注释清洗后只剩装饰时丢弃（块注释内与含界定符的行不丢）。
EMPTY_BODY = re.compile(r"^[\s：:，,、/;；()（）【】─—\-*。.\u3000]*$")


class Hit:
    __slots__ = ("path", "line", "before", "kind")

    def __init__(self, path: str, line: int, before: str, kind: str):
        self.path, self.line, self.before, self.kind = path, line, before, kind


def scrub_segment(seg: str, in_string: bool = False) -> tuple[str, str | None]:
    """清洗一段纯注释/字符串文本。返回 (新文本, 命中码族或 None)。

    in_string=True（app/test 展示串）：只清洗"永不可能是合法数据"的码族
    ——ADR 码/节号/箭头裸码/VR/PF/工单号/产物名/refs。裸车道码与
    X#-P#-# 族**退出字符串模式**：'Q1'/'Q2' 是协议载荷的问题键、
    'B2' 类短串可作夹具数据（公开树 analyze 曾现 equal_keys——
    {'Q1':'b','Q2':'x,y'} 被洗成 {'':'b','':'x,y'} 且测试因输入断言
    同损而仍绿，夹具形状掩盖，public-trust-1 抓出）。
    """
    orig = seg
    kind = None

    def mark(name: str) -> None:
        nonlocal kind
        kind = kind or name

    for pat, repl in WORD_MAP:
        if pat.search(seg):
            seg = pat.sub(repl, seg)
            mark("裸 ADR 词")
    if not in_string:
        for pat, repl in REFS_MAP:
            if pat.search(seg):
                seg = pat.sub(repl, seg)
                mark("refs 路径")
        for pat in DROP_TOKENS:
            if pat.search(seg):
                seg = pat.sub("", seg)
                mark("内部产物名")
    string_safe_names = {"ADR 码", "内部文档节号", "ADR 裸码速记",
                         "视觉审查票号", "缺陷账本票号", "批次工单号"}
    for pat, name in CODE_TOKENS:
        if in_string and name not in string_safe_names:
            continue
        if pat.search(seg):
            seg = pat.sub("", seg)
            mark(name)
    if not in_string and BARE_LANE.search(seg):
        def _bare(m: re.Match) -> str:
            return m.group(0) if m.group(0).rstrip("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳") in BARE_EXCLUDE else ""
        seg = BARE_LANE.sub(_bare, seg)
        if not kind and any(t.rstrip("①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳") not in BARE_EXCLUDE
                            for t in BARE_LANE.findall(orig)):
            mark("裸车道码")
    if seg == orig:
        return orig, None
    for _ in range(4):
        prev = seg
        for i, (pat, repl) in enumerate(PUNCT_CLEANUPS):
            if in_string and i in STRING_UNSAFE_PUNCT:
                continue
            seg = pat.sub(repl, seg)
        if not in_string:
            # 注释模式：被删 token 遗留的 CJK 间孤立斜杠（"审查 / 修正"
            # ← "审查 Q1 P2-1 / Q2 P1-1 修正"）收敛为顿号；字符串是数据不动。
            seg = re.sub(r"(?<=[\u4e00-\u9fff])\s+/\s+(?=[\u4e00-\u9fff）)])", "、", seg)
        # 行首孤立的装饰（token 原在行首：A3：xxx → ：xxx → xxx）。
        seg = re.sub(r"^[\s：:，,、/;；]+", "", seg)
        if seg == prev:
            break
    return seg, kind


def find_line_comment_slash(text: str) -> int:
    """// 注释起点（字符串内的 // 不算，如 URL）。无则 -1。"""
    i, n, quote = 0, len(text), None
    while i < n:
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif text.startswith("//", i):
            return i
        elif text.startswith("/*", i):
            return i
        i += 1
    return -1


def find_line_comment_hash(text: str) -> int:
    """# 注释起点。要求 # 位于行首或空白后，且后跟空白/行尾——
    排除 #F8F8F8 色值与 value#tag 形态。"""
    i, n, quote = 0, len(text), None
    while i < n:
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "#":
            prev_ok = i == 0 or text[i - 1] in " \t"
            next_ok = i + 1 >= n or text[i + 1] in " \t"
            if prev_ok and next_ok:
                return i
        i += 1
    return -1


def scrub_dart_string_literals(code: str) -> tuple[str, bool]:
    """清洗一行 Dart 代码内的字符串字面量（测试展示串场景）。"""
    out, i, n, touched = [], 0, len(code), False
    while i < n:
        ch = code[i]
        if ch not in ("'", '"'):
            out.append(ch)
            i += 1
            continue
        quote = ch
        j, buf = i + 1, []
        while j < n:
            cj = code[j]
            if cj == "\\" and j + 1 < n:
                buf.append(code[j:j + 2])
                j += 2
                continue
            if cj == quote:
                break
            buf.append(cj)
            j += 1
        inner = "".join(buf)
        cleaned, _ = scrub_segment(inner, in_string=True)
        if cleaned != inner:
            touched = True
            cleaned = cleaned.lstrip()
        out.append(quote + cleaned + quote if j < n else quote + cleaned)
        i = j + 1 if j < n else n
    return "".join(out), touched


def split_eol(line: str) -> tuple[str, str]:
    for eol in ("\r\n", "\n"):
        if line.endswith(eol):
            return line[:-len(eol)], eol
    return line, ""


def process_file(path: Path, rel: str, check_only: bool, hits: list[Hit]) -> bool:
    """返回 True=文件有改动/命中。check_only 只记录不写。"""
    suffix = path.suffix.lower()
    if suffix in SLASH_EXT:
        family = "slash"
    elif suffix in HASH_EXT:
        family = "hash"
    elif suffix in XML_EXT:
        family = "xml"
    else:
        return False

    try:
        text = path.read_bytes().decode("utf-8")
    except UnicodeDecodeError:
        return False
    lines = text.splitlines(keepends=True)
    dropped: set[int] = set()
    in_block = False  # /* */ 或 <!-- --> 块内
    changed = False

    for ln, line in enumerate(lines, 1):
        body, eol = split_eol(line)
        code_part, comment_part = body, ""

        if family == "xml":
            if in_block:
                end = body.find("-->")
                comment_part, code_part = body, ""
                in_block = end == -1
            elif "<!--" in body:
                start = body.find("<!--")
                end = body.find("-->", start)
                code_part, comment_part = body[:start], body[start:]
                in_block = end == -1
        elif family == "slash":
            if in_block:
                end = body.find("*/")
                comment_part, code_part = body, ""
                in_block = end == -1
            else:
                idx = find_line_comment_slash(body)
                if idx >= 0:
                    code_part, comment_part = body[:idx], body[idx:]
                    in_block = body.startswith("/*", idx) and "*/" not in body[idx + 2:]
        else:  # hash
            idx = find_line_comment_hash(body)
            if idx >= 0:
                code_part, comment_part = body[:idx], body[idx:]

        new_comment = None
        kind = None
        if comment_part:
            m = re.match(r"^(\s*)((?:/+|#|\*))(\s?)(.*)$", comment_part)
            if m and m.group(4) != "":
                seg, kind = scrub_segment(m.group(4))
                if seg != m.group(4):
                    new_comment = m.group(1) + m.group(2) + m.group(3) + seg
            elif family == "xml":
                # xml 行：<!-- 可能独占开行——先剥 <!-- 与可选 --> 再洗，
                # 否则行首孤立冒号清理被 "<!--" 挡住（终审建议："<！-- ：关闭…"）。
                m2 = re.match(r"^(\s*<!--\s*)(.*?)(\s*-->\s*)$", comment_part, re.S)
                if not m2:
                    m2 = re.match(r"^(\s*<!--\s*)(.*)$", comment_part)
                if m2 and m2.group(2):
                    seg, kind = scrub_segment(m2.group(2))
                    if seg != m2.group(2):
                        new_comment = m2.group(1) + seg + (m2.group(3) if m2.lastindex >= 3 else "")
                else:
                    seg, kind = scrub_segment(comment_part)
                    if seg != comment_part:
                        new_comment = seg
            else:
                seg, kind = scrub_segment(comment_part)
                if seg != comment_part:
                    new_comment = seg

        new_code = None
        if suffix == ".dart" and rel.replace("\\", "/").startswith("app/test/") and code_part:
            scrubbed, touched = scrub_dart_string_literals(code_part)
            if touched:
                new_code = scrubbed

        if new_comment is None and new_code is None:
            continue
        changed = True
        merged = (new_code if new_code is not None else code_part) + \
                 (new_comment if new_comment is not None else comment_part)
        hits.append(Hit(rel, ln, body, kind or "测试展示串"))
        if not check_only:
            stripped = re.sub(r"^(?:/+|#|\*+|<!--|-->)", "", merged).strip()
            droppable = (
                not in_block and "<!--" not in merged and "-->" not in merged
                and not stripped.startswith("*/") and EMPTY_BODY.match(stripped or "")
            )
            if droppable:
                dropped.add(ln - 1)
            else:
                lines[ln - 1] = merged + eol

    if changed and not check_only:
        out = [l for i, l in enumerate(lines) if i not in dropped]
        path.write_bytes("".join(out).encode("utf-8"))
    return changed


SKIP_DIRS = {".git", ".dart_tool", "build", ".gradle", ".kotlin", ".idea",
             "node_modules"}


def run(root: str, check_only: bool) -> list[Hit]:
    rootp = Path(root)
    hits: list[Hit] = []
    exts = SLASH_EXT | HASH_EXT | XML_EXT
    for p in sorted(rootp.rglob("*")):
        if not p.is_file():
            continue
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.suffix.lower() in exts:
            process_file(p, str(p.relative_to(rootp)).replace("\\", "/"), check_only, hits)
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description="公开树内部引用清洗/检查")
    ap.add_argument("root", help="导出树根目录")
    ap.add_argument("--check", action="store_true", help="只检查不修改，残留退出码 1")
    ap.add_argument("--report", help="替换/命中清单落盘路径")
    args = ap.parse_args()

    hits = run(args.root, args.check)
    status = "FAIL" if (args.check and hits) else "OK"
    print(f"[hygiene] {'检查' if args.check else '清洗'}完成：{len(hits)} 处"
          f"{'残留' if args.check else '清洗'}（{status}）")
    for h in hits[:400]:
        print(f"  {h.path}:{h.line} [{h.kind}]  {h.before.strip()[:140]}")
    if len(hits) > 400:
        print(f"  …另有 {len(hits) - 400} 处")
    if args.report:
        with open(args.report, "w", encoding="utf-8", newline="\n") as fh:
            for h in hits:
                fh.write(f"{h.path}:{h.line} [{h.kind}]\n  {h.before.strip()}\n")
        print(f"[hygiene] 清单已写入 {args.report}")
    return 1 if (args.check and hits) else 0


if __name__ == "__main__":
    sys.exit(main())
