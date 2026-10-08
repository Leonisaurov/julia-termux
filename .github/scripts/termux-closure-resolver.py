"""Resolve the transitive .deb closure of a set of Termux aarch64 packages.

Reads a Debian `Packages` index (uncompressed) from argv[1] and writes repository
relative paths, one per line, to stdout.  Names that cannot be resolved are reported
on stderr; the script fails only when a requested root package is absent, because a
missing leaf (a virtual package, an Pre-Depends on something Termux expresses
differently) must not abort the probe.
"""
import re
import sys
from pathlib import Path

ROOTS = [
    "clang", "lld", "llvm", "libllvm", "libcompiler-rt", "ndk-sysroot", "binutils",
    "libc++", "libandroid-support", "zlib", "zstd", "ncurses", "make", "ninja",
    "cmake", "pkg-config", "perl", "python", "git", "patch", "dash", "bash",
    "coreutils", "grep", "sed", "tar", "gzip", "bzip2", "xz-utils", "which", "file",
    "findutils", "diffutils", "ed", "ca-certificates", "openssl", "libiconv",
    "pcre2", "libexpat", "liblzma",
]


def parse(index_path):
    packages = {}
    for block in Path(index_path).read_text(errors="replace").split("\n\n"):
        name = re.search(r"^Package: (.*)$", block, re.M)
        filename = re.search(r"^Filename: (.*)$", block, re.M)
        if not name or not filename:
            continue
        depends = re.search(r"^(?:Depends|Pre-Depends): (.*)$", block, re.M)
        packages[name.group(1).strip()] = (
            filename.group(1).strip(),
            depends.group(1) if depends else "",
        )
    return packages


def dep_names(spec):
    for alternative in spec.split(","):
        first = alternative.split("|")[0].strip()
        name = re.split(r"\s*\(", first)[0].strip()
        if name:
            yield name


def main():
    index = sys.argv[1] if len(sys.argv) > 1 else "Packages"
    roots = sys.argv[2:] or ROOTS
    packages = parse(index)
    resolved, missing = {}, set()
    frontier = list(roots)
    while frontier:
        current = frontier.pop()
        if current in resolved:
            continue
        if current not in packages:
            missing.add(current)
            continue
        filename, depends = packages[current]
        resolved[current] = filename
        frontier.extend(dep_names(depends))

    seen_files = set()
    for name in sorted(resolved):
        if resolved[name] not in seen_files:
            seen_files.add(resolved[name])
            print(resolved[name])
    roots_missing = [name for name in roots if name in missing]
    print(f"# resolved={len(resolved)} unresolved={len(missing)}", file=sys.stderr)
    if missing:
        print("# unresolved: " + " ".join(sorted(missing)), file=sys.stderr)
    if roots_missing:
        print("# ERROR missing roots: " + " ".join(roots_missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
