"""Read literal map objects only; never execute scripts from the supplied HTML."""
import hashlib
import html
import re
from html.parser import HTMLParser


class Sections(HTMLParser):
    """Retain free research prose, not just the diagram's small shared envelope."""
    def __init__(self):
        super().__init__()
        self.sections = []
        self.current = {"title": "原稿说明", "body": ""}
        self.heading = False
        self.hidden = 0

    def handle_starttag(self, tag, attrs):
        if tag in {"script", "style"}:
            self.hidden += 1
        if self.hidden:
            return
        if tag == "h2":
            if self.current["body"].strip():
                self.sections.append(self.current)
            self.current = {"title": "", "body": ""}
            self.heading = True
        if tag in {"p", "li", "tr", "h3", "br", "details"}:
            self.current["body"] += "\n"

    def handle_endtag(self, tag):
        if tag in {"script", "style"}:
            self.hidden = max(0, self.hidden - 1)
        if tag == "h2":
            self.heading = False
        if not self.hidden and tag == "td":
            self.current["body"] += " | "

    def handle_data(self, value):
        if not self.hidden:
            self.current["title" if self.heading else "body"] += value


class LiteralParser:
    def __init__(self, text):
        self.text, self.i = text, 0

    def skip(self):
        while self.i < len(self.text):
            m = re.match(r"\s+|//[^\n]*(?:\n|$)|/\*.*?\*/", self.text[self.i:], re.S)
            if not m:
                return
            self.i += len(m.group())

    def value(self):
        self.skip()
        c = self.text[self.i]
        if c in "[ {".replace(" ", ""):
            self.i += 1
            result = [] if c == "[" else {}
            end = "]" if c == "[" else "}"
            while True:
                self.skip()
                if self.text[self.i] == end:
                    self.i += 1
                    return result
                if c == "[":
                    result.append(self.value())
                else:
                    self.skip()
                    if self.text[self.i] in "\"'":
                        key = self.value()
                    else:
                        m = re.match(r"[A-Za-z_$][\w$]*", self.text[self.i:])
                        if not m:
                            raise ValueError("不是受支持的对象键")
                        key = m.group()
                        self.i += len(key)
                    self.skip()
                    if self.text[self.i] != ":":
                        raise ValueError("对象缺少冒号")
                    self.i += 1
                    result[key] = self.value()
                self.skip()
                if self.text[self.i] == ",":
                    self.i += 1
                elif self.text[self.i] != end:
                    raise ValueError("仅支持字面数据，不执行表达式")
        if c in "\"'":
            quote, out = c, []
            self.i += 1
            while self.i < len(self.text):
                char = self.text[self.i]
                self.i += 1
                if char == quote:
                    return "".join(out)
                if char == "\\":
                    esc = self.text[self.i]
                    self.i += 1
                    if esc == "u":
                        out.append(chr(int(self.text[self.i:self.i + 4], 16)))
                        self.i += 4
                    else:
                        out.append({"n": "\n", "t": "\t", "r": "\r"}.get(esc, esc))
                else:
                    out.append(char)
            raise ValueError("字符串没有结束")
        m = re.match(r"-?\d+(?:\.\d+)?|true\b|false\b|null\b", self.text[self.i:])
        if not m:
            raise ValueError("不是受支持的字面值")
        self.i += len(m.group())
        import json
        return json.loads(m.group())


def clean(text):
    return html.unescape(re.sub(r"<[^>]*>", "", str(text)))


def parse_map(text, track, source_name, observed_at):
    if len(text) > 2_000_000 or not re.fullmatch(r"[a-z][a-z0-9_-]{1,60}", track):
        raise ValueError("来源超限或板块不合法")
    values = {}
    for name in ("GROUPS", "B"):
        match = re.search(r"\bconst\s+" + name + r"\s*=\s*", text)
        if not match:
            raise ValueError("未找到 " + name)
        values[name] = LiteralParser(text[match.end():]).value()
    for name in ("chipText", "EXT"):
        match = re.search(r"\bconst\s+" + name + r"\s*=\s*", text)
        if match:
            values[name] = LiteralParser(text[match.end():]).value()
    groups, blocks = values["GROUPS"], values["B"]
    if not isinstance(groups, list) or not isinstance(blocks, dict) or not 1 <= len(blocks) <= 1000:
        raise ValueError("板块结构无效")
    rows = []
    for group in groups:
        for bid in group["ids"]:
            b = blocks[bid]
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,30}", bid):
                raise ValueError("块编号无效")
            notes = [clean(x) for x in b.get("f", [])]
            rows.append({"id": track + ":" + bid, "track": track, "group": clean(group["name"]),
                         "order": len(rows), "source_color": clean(b.get("c", "gray")),
                         "source_label": clean(values.get("chipText", {}).get(b.get("c"), "未记录判断")),
                         "short_note": clean(b.get("w", b.get("tk", ""))).split("；")[0],
                         "title": clean(b["n"]), "purpose": clean(b.get("u", "")), "notes": notes,
                         "source_status_text": clean(b.get("h", "")), "source_plan": clean(b.get("l", "")),
                         "references": [clean(b.get("d", ""))], "neighbors": clean(b.get("k", "")),
                         "ticket_ids": sorted(set(re.findall(r"COR-\d+", str(b))))})
    if len({r["id"] for r in rows}) != len(rows) or len(rows) != len(blocks):
        raise ValueError("分组和板块成员不一致")
    sections = Sections()
    sections.feed(text)
    if sections.current["body"].strip():
        sections.sections.append(sections.current)
    return {"track": track, "name": source_name, "observed_at": observed_at, "blocks": rows,
            "legend": {k: clean(v) for k, v in values.get("chipText", {}).items()},
            "groups": groups, "external": values.get("EXT", []), "sections": sections.sections,
            "digest": hashlib.sha256(text.encode()).hexdigest()}
