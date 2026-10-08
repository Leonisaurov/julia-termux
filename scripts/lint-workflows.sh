#!/data/data/com.termux/files/usr/bin/bash
# Static gate for CI YAML: syntax-check every `run:` body with bash -n before any run
# is dispatched.  Covers .github/workflows/*.yml and .github/actions/*/action.yml,
# because a composite action is executed by every job that uses it, so a typo there
# costs the same runner spin-up as a typo in a workflow.
#
# Why: GitHub executes each run block as `bash -e {0}`, so a syntax error or an
# unguarded non-zero command costs a full runner spin-up and tells us nothing
# about the hypothesis the run was meant to test.  Both happened at least once.
#
# Usage: bash scripts/lint-workflows.sh [file.yml ...]   (default: all)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOWS=("${@:-}")
if [ -z "${WORKFLOWS[*]}" ]; then
	mapfile -t WORKFLOWS < <(ls "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/actions/*/action.yml 2>/dev/null)
fi

fail=0
TMPD="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
for wf in "${WORKFLOWS[@]}"; do
	bodies="$(mktemp -d "$TMPD/julia-lint.XXXXXX")"
	if ! python3 - "$wf" "$bodies" <<'PY'
import sys, yaml, pathlib
wf, outdir = sys.argv[1], sys.argv[2]
def die(msg):
    print(f"YAML  {msg}", file=sys.stderr)
    raise SystemExit(1)
def where(exc):
    mark = getattr(exc, "problem_mark", None) or getattr(exc, "mark", None)
    if mark is None:
        return None
    # safe_load() of a string labels the stream "<unicode string>", which says nothing
    # about which file to open.
    name = wf if not mark.name or mark.name.startswith("<") else mark.name
    return f"{name}:{mark.line + 1}:{mark.column + 1}"
try:
    # A file that does not parse has no run blocks to check, and silently reporting zero
    # of them is how an unparseable workflow once passed this gate.
    doc = yaml.safe_load(pathlib.Path(wf).read_text())
except yaml.MarkedYAMLError as e:
    # PyYAML re-raises the inner scanner error, so the traceback is 40 frames of noise;
    # the position is the whole message here.
    pos, detail = where(e), (e.problem or e.context or "parse error")
    die(f"{pos or wf}: {detail}")
except Exception as e:
    die(f"{wf}: {type(e).__name__}: {e}")
if not isinstance(doc, dict):
    die(f"{wf}: not a mapping at top level")
jobs = doc.get("jobs")
if not jobs and isinstance(doc.get("runs"), dict):
    # Composite action: runs.steps has the same shape as a job's steps.
    jobs = {"action": doc["runs"]}
pathlib.Path(outdir).mkdir(exist_ok=True)
i = skipped = 0
for jname, job in (jobs or {}).items():
    if not isinstance(job, dict):
        die(f"{wf}: job {jname!r} is not a mapping")
    for st in job.get("steps", []):
        body = st.get("run")
        if body is None:
            continue
        i += 1
        shell = (st.get("shell") or "").lower()
        if shell.startswith("powershell") or shell.startswith("pwsh"):
            skipped += 1
            continue
        name = st.get("name") or (st.get("uses") or "step")
        pathlib.Path(outdir, f"{i:02d}-{jname}-{name}".replace("/", "_") + ".sh").write_text(body)
if skipped:
    print(f"skipped {skipped} non-bash run blocks", file=sys.stderr)
PY
	then
		printf 'FAIL  %s (yaml)\n' "${wf#"$REPO_ROOT"/}"
		fail=$((fail + 1))
		rm -rf "$bodies"
		continue
	fi
	n=$(ls "$bodies" 2>/dev/null | wc -l)
	printf -- '-- %s (%s run blocks)\n' "${wf#"$REPO_ROOT"/}" "$n"
	if [ "$n" -eq 0 ]; then
		# Legitimate for a run-free action, but the last time this happened it was a
		# misindented `run:` key, so say so out loud rather than printing nothing.
		echo "WARN  no bash run blocks found - check that steps and run: are indented under the job"
	fi
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

# A `uses: ./path` step must name a directory that actually carries an action.yml:
# GitHub resolves it against the repository root when the job starts, so a stale path
# costs a full runner spin-up for an error a filesystem check gives for free.
for wf in "${WORKFLOWS[@]}"; do
	while IFS= read -r ref; do
		if [ -f "$REPO_ROOT/${ref}/action.yml" ] || [ -f "$REPO_ROOT/${ref}/action.yaml" ]; then
			printf 'OK    %s -> %s\n' "${wf#"$REPO_ROOT"/}" "$ref"
		else
			printf 'FAIL  %s -> %s (no action.yml)\n' "${wf#"$REPO_ROOT"/}" "$ref"
			fail=$((fail + 1))
		fi
	done < <(grep -oE 'uses:[[:space:]]*\./[^[:space:]]+' "$wf" | sed -E 's/^uses:[[:space:]]*//; s#^\./##')
done

if [ "$fail" -gt 0 ]; then
	echo "GATE: FAIL ($fail problems: unparseable yaml, run blocks that do not parse, or dead uses: paths)"
	exit 1
fi
echo "GATE: PASS (all yaml parses, all run blocks parse, all local uses: resolve)"
