#!/data/data/com.termux/files/usr/bin/python3
"""Print the file operands of every `sed` call in a shell script, one per line.

Quoted regions are the sed *scripts* (patterns), so they are removed before
tokenising; what survives is the command's real operands.  Without this, a
pattern like 's/^typedef .../ contains slashes and reads as a path, and the
rehearsal gate drowns its genuine findings in phantom MISS lines.
"""
import re
import sys

BUILD_FILES = ("Makefile", "Make.inc", "configure.ac", "CMakeLists.txt", "make.sh")


def strip_quoted(text):
    """Blank out single/double quoted regions, keeping their delimiters as spaces."""
    out = []
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            out.append(" ")
            if ch == "\\" and quote == '"' and i + 1 < len(text):
                out.append(" ")
                i += 1
            elif ch == quote:
                quote = None
        else:
            if ch in ("'", '"'):
                quote = ch
                out.append(" ")
            elif ch == "\\" and i + 1 < len(text) and text[i + 1] in "'\"":
                out.append(" ")
                i += 1
            else:
                out.append(ch)
        i += 1
    return "".join(out)


def join_continuations(source):
    """Splice backslash-continued lines so multi-line sed commands are one item."""
    lines = []
    pending = ""
    for raw in source.splitlines():
        line = pending + raw
        pending = ""
        if line.endswith("\\"):
            pending = line[:-1]
            continue
        lines.append(line)
    if pending:
        lines.append(pending)
    return lines


def operands(line):
    """Tokens of the sed statement, with scripts and shell redirections removed."""
    match = re.search(r"(^|[;&|(\s])sed(\s|$)", line)
    if match is None:
        return
    body = line[match.end() - 1:]
    for sep in ("||", "&&", ";"):
        body = body.split(sep)[0]
    body = strip_quoted(body)
    for tok in reversed(body.split()):
        tok = tok.strip("(){}")
        if not tok or tok.startswith("-"):
            continue
        if re.search(r"[<>|&*?$`]", tok):
            continue
        yield tok


def looks_like_target(tok):
    return "/" in tok or tok in BUILD_FILES


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} SCRIPT", file=sys.stderr)
        return 2
    source = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    # target -> shallowest indentation among the sed statements naming it.
    # Indentation is how the caller tells a top-level patch from one buried in
    # `if [ -n "$SOME_LIB" ]`, which a rehearsal with a fake prefix cannot reach.
    depths = {}
    statements = 0
    unresolved = 0
    for line in join_continuations(source):
        if re.search(r"(^|[;&|(\s])sed(\s|$)", line) is None:
            continue
        statements += 1
        indent = len(line) - len(line.lstrip())
        matched = False
        for tok in operands(line):
            if looks_like_target(tok):
                matched = True
                if tok in depths:
                    depths[tok] = min(depths[tok], indent)
                else:
                    depths[tok] = indent
        if not matched:
            unresolved += 1
    for tok in sorted(depths):
        print(f"{depths[tok]}\t{tok}")
    # An operand built from a loop variable ($f) or a prefix ($src) is not
    # statically resolvable; say so instead of quietly shrinking the report.
    print(f"# sed_statements={statements} resolved={statements - unresolved} "
          f"unresolved={unresolved}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
