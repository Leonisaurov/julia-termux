"""Resolve the transitive .deb closure of a set of Termux aarch64 packages.

Reads a Debian `Packages` index (uncompressed) from argv[1] and writes repository
relative paths, one per line, to stdout.  Names that cannot be resolved are reported
on stderr; the script fails only when a requested root package is absent, because a
missing leaf (a virtual package, an Pre-Depends on something Termux expresses
differently) must not abort the whole prefix setup.

The default roots are the bootstrap set of scripts/generate-bootstraps.sh in
termux-packages, trimmed to what a build prefix needs, plus the Tier 1 of
scripts/setup-termux.sh - the tools the core build scripts themselves exec.  Roots
given on the command line are added to them, not substituted for them: the caller
passes the recipe's own TERMUX_PKG_DEPENDS and TERMUX_PKG_BUILD_DEPENDS, and a
prefix without the bootstrap is not a prefix at all.

Nothing here reaches the network: these runners cannot resolve DNS from inside
bionic (measured on run 37782123436 - apt's https method reports
"No address associated with hostname" while the host's curl resolves the same
name), so the whole set a build needs has to come out of this one closure.
"""
import re
import sys
from pathlib import Path

ROOTS = [
    "apt", "bash", "bzip2", "coreutils", "curl", "dash", "debianutils", "diffutils",
    "findutils", "gawk", "grep", "gzip", "patch", "procps", "psmisc", "sed", "tar",
    "termux-core", "termux-exec", "termux-keyring", "termux-tools", "util-linux",
    "xz-utils",
    # termux_step_start_build.sh:125 runs `apt install -y termux-elf-cleaner`
    # unconditionally for every bionic on-device build.  With the package extracted
    # and seeded in dpkg/status that call answers "already the newest version" and
    # returns 0 even with empty apt lists (measured with apt-get -s on a real
    # prefix); without it the build dies before configuring anything.
    "termux-elf-cleaner",
    # Tier 1 of termux-packages' own scripts/setup-termux.sh - "requirements for
    # the core build scripts in scripts/build/" - that the bootstrap above does
    # not already cover.  build-package.sh:64 reads repo.json through jq on every
    # invocation, before any package is parsed: run 37790992541 died there with
    # "./build-package.sh: line 64: /usr/bin/jq: cannot execute: required file
    # not found", because libtermux-exec rewrites /usr/bin/jq into the prefix,
    # where no jq had been extracted (see the aliasing note in AGENTS.md).  unzip
    # is what termux_unpack_src_archive.sh:13 uses for *.zip sources and lzip is
    # the *.tar.lz handler tar looks for.
    #
    # Deliberately absent from this list: python (Tier 1 too, but already a root
    # through the recipe's TERMUX_PKG_BUILD_DEPENDS) and gnupg, whose only use in
    # the build path is build-package.sh:657-672 and termux_get_repo_files.sh:42 -
    # both guarded so that `-s` (TERMUX_SKIP_DEPCHECK=true,
    # termux_step_get_dependencies.sh:2) never reaches them.
    "jq", "lzip", "unzip",
]


def parse(index_path):
    packages = {}
    for block in Path(index_path).read_text(errors="replace").split("\n\n"):
        name = re.search(r"^Package: (.*)$", block, re.M)
        filename = re.search(r"^Filename: (.*)$", block, re.M)
        if not name or not filename:
            continue
        depends = " ".join(re.findall(r"^(?:Depends|Pre-Depends): (.*)$", block, re.M))
        packages[name.group(1).strip()] = (
            filename.group(1).strip(),
            depends,
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
    roots = sorted(set(ROOTS) | {name for name in sys.argv[2:] if name})
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
