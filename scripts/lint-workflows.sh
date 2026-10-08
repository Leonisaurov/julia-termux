#!/data/data/com.termux/files/usr/bin/bash
# Static gate for .github/workflows/*.yml: syntax-check every `run:` body with
# bash -n before any run is dispatched.
#
# Why: GitHub executes each run block as `bash -e {0}`, so a syntax error or an
# unguarded non-zero command costs a full runner spin-up and tells us nothing
# about the hypothesis the run was meant to test.  Both happened at least once.
#
# Usage: bash scripts/lint-workflows.sh [workflow.yml ...]   (default: all)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS=("${@:-}")
if [ -z "${WORKFLOWS[*]}" ]; then
	mapfile -t WORKFLOWS < <(ls "$REPO_ROOT"/.github/workflows/*.yml)
fi

fail=0
TMPD="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
for wf in "${WORKFLOWS[@]}"; do
	bodies="$(mktemp -d "$TMPD/julia-lint.XXXXXX")"
	python3 - "$wf" "$bodies" <<'PY'
import sys, yaml, pathlib
wf, outdir = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(pathlib.Path(wf).read_text())
pathlib.Path(outdir).mkdir(exist_ok=True)
i = 0
for jname, job in (doc.get("jobs") or {}).items():
    for st in job.get("steps", []):
        body = st.get("run")
        if body is None:
            continue
        i += 1
        shell = (st.get("shell") or "").lower()
        if shell.startswith("powershell") or shell.startswith("pwsh"):
            continue
        name = st.get("name") or (st.get("uses") or "step")
        pathlib.Path(outdir, f"{i:02d}-{jname}-{name}".replace("/", "_") + ".sh").write_text(body)
print(i)
PY
	n=$(ls "$bodies" 2>/dev/null | wc -l)
	printf -- '-- %s (%s run blocks)\n' "$(basename "$wf")" "$n"
	for b in "$bodies"/*; do
		[ -e "$b" ] || continue
		if bash -n "$b" 2>"$b.err"; then
			printf 'OK    %s\n' "$(basename "$b")"
		else
			printf 'FAIL  %s\n' "$(basename "$b")"
			sed 's/^/        /' "$b.err"
			fail=$((fail + 1))
		fi
	done
	rm -rf "$bodies"
done

# The `-e` hazard: a bare command that can legitimately fail aborts the whole
# step before its own diagnostics run.  Flag it as a warning, not an error.
for wf in "${WORKFLOWS[@]}"; do
	hits=$(grep -nE '^\s+(timeout|make|cmake|ninja|./build-package.sh|curl|wget) ' "$wf" \
		| grep -vE '\|\||\|\s*(cat|tail|tee|grep)' || true)
	if [ -n "$hits" ]; then
		echo "WARN  possible abort-on-first-failure (capture rc with '|| rc=\$?' if the step must keep going):"
		echo "$hits" | sed 's/^/        /'
	fi
done

if [ "$fail" -gt 0 ]; then
	echo "GATE: FAIL ($fail run blocks with syntax errors)"
	exit 1
fi
echo "GATE: PASS (all run blocks parse)"
