#!/usr/bin/env python3
"""Text-level Swift structure scanner for scripts/lint-structure-ownership.sh.

It is not a Swift parser. Comments and string literals are blanked first, so
braces inside them do not count, then declarations are read at brace depth 1
of each type or extension block. That is enough for the declarations this
repository writes; an unusual layout can miscount, and the lint reports the
per-file numbers so a miscount is visible.

Subcommands (paths are relative to the checkout root):
  members <type>...        one line per file: "<type> <file> <count>"
  requirement-defaults     one line per default: "<Protocol>.<key> <file>"
  store-conformances       one line per repository protocol the store adopts
"""
import os
import re
import sys

SOURCE_ROOTS = ("Actualist", "ActualistWidget")
REPOSITORY_DIR = os.path.join("Actualist", "Repositories")

MODIFIERS = (
    r"(?:@[\w.]+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|open|package|static|class|final|"
    r"override|mutating|nonmutating|nonisolated|isolated|lazy|weak|unowned|"
    r"required|convenience|dynamic|optional|indirect|consuming|borrowing|"
    r"distributed|@\w+)(?:\([^)]*\))?\s+)*"
)
MEMBER_RE = re.compile(
    r"^\s*" + MODIFIERS +
    r"(func|init|deinit|subscript|var|let|struct|enum|class|actor|typealias|protocol)\b(\??)\s*([^\s(<:={]*)"
)
# A store collaborator declaration is allowed: the store owns its
# <Domain>Workflows collaborators (AGENTS.md, Domain Ownership And Central Types).
COLLABORATOR_RE = re.compile(r"\blazy\s+var\s+\w+\s*=\s*\w+Workflows\(")


def swift_files():
    for root in SOURCE_ROOTS:
        for dirpath, _, names in os.walk(root):
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def blank(source):
    """Replace comment and string contents with spaces, keeping newlines."""
    out = []
    i, n = 0, len(source)
    # Each frame: ("code", paren_depth) or ("string", delimiter, hashes).
    stack = [("code", 0)]
    while i < n:
        frame = stack[-1]
        c = source[i]
        if frame[0] == "code":
            if source.startswith("//", i):
                j = source.find("\n", i)
                j = n if j == -1 else j
                out.append(" " * (j - i))
                i = j
                continue
            if source.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if source.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif source.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                out.append(re.sub(r"[^\n]", " ", source[i:j]))
                i = j
                continue
            m = re.match(r'(#*)("""|")', source[i:i + 12])
            if m and (m.group(1) == "" or c == "#"):
                hashes, delim = m.group(1), m.group(2)
                out.append(" " * len(m.group(0)))
                i += len(m.group(0))
                stack.append(("string", delim, hashes))
                continue
            if c == "(" and len(stack) > 1:
                stack[-1] = ("code", frame[1] + 1)
            elif c == ")" and len(stack) > 1:
                if frame[1] == 0:
                    stack.pop()  # end of an interpolation
                    out.append(" ")
                    i += 1
                    continue
                stack[-1] = ("code", frame[1] - 1)
            out.append(c)
            i += 1
            continue
        _, delim, hashes = frame
        if c == "\\" and source.startswith("\\" + hashes + "(", i):
            width = len(hashes) + 2
            out.append(" " * width)
            i += width
            stack.append(("code", 0))
            continue
        if c == "\\" and not hashes:
            out.append("  " if i + 1 < n and source[i + 1] != "\n" else " ")
            i += 2 if i + 1 < n and source[i + 1] != "\n" else 1
            continue
        if source.startswith(delim + hashes, i):
            width = len(delim) + len(hashes)
            out.append(" " * width)
            i += width
            stack.pop()
            continue
        out.append("\n" if c == "\n" else " ")
        i += 1
    return "".join(out)


def blocks(code, header_re):
    """Yield (match, header_text, body_lines) for each top-level block whose
    header matches. Body lines start after the opening brace."""
    lines = code.split("\n")
    depth = 0
    k = 0
    while k < len(lines):
        line = lines[k]
        m = header_re.match(line) if depth == 0 else None
        if not m:
            depth += line.count("{") - line.count("}")
            k += 1
            continue
        # The opening brace may sit on a later line (a wrapped where clause).
        j = k
        while j < len(lines) and "{" not in lines[j]:
            j += 1
        if j == len(lines):
            return
        header = " ".join(lines[k:j + 1])
        first = lines[j][lines[j].index("{") + 1:]
        body = [first]
        d = 1 + first.count("{") - first.count("}")
        j += 1
        while j < len(lines) and d > 0:
            body.append(lines[j])
            d += lines[j].count("{") - lines[j].count("}")
            j += 1
        yield m, header, body
        k = j


def depth_one(body):
    """Yield (line, depth_before) for lines in a block body."""
    d = 1
    for line in body:
        yield line, d
        d += line.count("{") - line.count("}")


def count_members(path, type_name):
    with open(path, encoding="utf-8") as f:
        code = blank(f.read())
    header = re.compile(
        r"^\s*" + MODIFIERS + r"(?:extension|actor|class|struct|enum)\s+" +
        re.escape(type_name) + r"(?![\w.])"
    )
    total = 0
    for _, _, body in blocks(code, header):
        for line, d in depth_one(body):
            if d != 1:
                continue
            m = MEMBER_RE.match(line)
            if not m or COLLABORATOR_RE.search(line):
                continue
            total += 1
    return total


def signature_key(kind, name, line_tail):
    if kind in ("var", "let", "typealias"):
        return name.rstrip(":")
    if kind == "init":
        name = "init"
    tail = line_tail
    start = tail.find("(")
    if start == -1:
        return name + "()"
    depth, j, params = 0, start, ""
    while j < len(tail):
        ch = tail[j]
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
            if depth == 0:
                break
        params += ch
        j += 1
    params = params[1:]
    labels, depth, part = [], 0, ""
    for ch in params + ",":
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            head = part.split(":", 1)[0].split()
            if head:
                labels.append(head[0] + ":")
            part = ""
        else:
            part += ch
    return name + "(" + "".join(labels) + ")"


def joined_declarations(body):
    """Depth-1 declarations with their parameter lists joined onto one line."""
    items = []
    lines = list(depth_one(body))
    i = 0
    while i < len(lines):
        line, d = lines[i]
        m = MEMBER_RE.match(line) if d == 1 else None
        if m:
            text = line
            j = i
            while text.count("(") > text.count(")") and j + 1 < len(lines):
                j += 1
                text += " " + lines[j][0]
            items.append((m.group(1), m.group(3), text[m.end(2):] if m.group(3) else text))
            i = j + 1
            continue
        i += 1
    return items


def requirement_defaults():
    files = [p for p in swift_files() if p.startswith(REPOSITORY_DIR + os.sep)]
    codes = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            codes[path] = blank(f.read())
    requirements = {}
    proto_header = re.compile(r"^\s*" + MODIFIERS + r"protocol\s+(\w+)")
    for path, code in codes.items():
        for m, _, body in blocks(code, proto_header):
            keys = set()
            for kind, name, tail in joined_declarations(body):
                if kind in ("func", "init", "subscript", "var", "let"):
                    keys.add(signature_key(kind, name, tail))
            requirements[m.group(1)] = keys
    results = []
    ext_header = re.compile(r"^\s*" + MODIFIERS + r"extension\s+(\w+)(?![\w.])")
    for path in sorted(codes):
        for m, _, body in blocks(codes[path], ext_header):
            proto = m.group(1)
            if proto not in requirements:
                continue
            for kind, name, tail in joined_declarations(body):
                key = signature_key(kind, name, tail)
                if key in requirements[proto]:
                    results.append(f"{proto}.{key} {path}")
    return results


def store_conformances():
    results = []
    header = re.compile(
        r"^\s*" + MODIFIERS + r"(?:extension|class)\s+LocalFirstActualStore(?![\w.])"
    )
    for path in sorted(swift_files()):
        with open(path, encoding="utf-8") as f:
            code = blank(f.read())
        for _, text, _ in blocks(code, header):
            head = text.split("{", 1)[0]
            for proto in re.findall(r"\b(\w*Repository\w*Protocol)\b", head):
                results.append(f"{proto} {path}")
    return results


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]
    if command == "members":
        for type_name in argv[2:]:
            for path in sorted(swift_files()):
                count = count_members(path, type_name)
                if count:
                    print(f"{type_name} {path} {count}")
        return 0
    if command == "requirement-defaults":
        print("\n".join(requirement_defaults()))
        return 0
    if command == "store-conformances":
        print("\n".join(store_conformances()))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
