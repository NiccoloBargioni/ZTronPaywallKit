#!/usr/bin/env bash
# Self-test for Scripts/coverage-gate.sh: the gate's own logic over stubbed toolchain commands and fixture reports,
# with no Swift build. Runs in CI's `forbidden-constructs` job (bash and python3 only).
#
# Cases, from the 2026-11-17 review (B7):
#   (a) a PaywallCore-only export with --baseline and no --targets fails, naming the four other targets as missing
#   (b) (a) with --write-baseline on a copy leaves the copy untouched
#   (c) all five targets, --targets "PaywallCore PaywallTesting", --baseline B --write-baseline B: passes, B unchanged
#   (d) PaywallCore's files under Sources/Core: fails, every crash-critical file "FAIL (no data)"
#   (e) a --baseline path that does not exist is an error
#   (f) PaywallSimulator present only in an --xccov report (no region data) fails against a baseline with regions
#   (g) the control, all five at 100 / 100, passes
#   plus: --retire drops a key from the union and from the written file; a failed run never writes the baseline
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(mktemp -d)"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/Scripts" "$ROOT/stubs" "$ROOT/.build/debug/codecov" "$ROOT/.build/debug/X.xctest"
cp Scripts/coverage-gate.sh "$ROOT/Scripts/coverage-gate.sh"
: > "$ROOT/.build/debug/codecov/default.profdata"

# Stubs first on PATH: `swift` answers the two queries the gate makes; `llvm-cov` and `xcrun llvm-cov` print the export
# named by STUB_EXPORT.
cat > "$ROOT/stubs/swift" <<SW
#!/usr/bin/env bash
case "\$*" in
  "test --show-codecov-path") echo "$ROOT/.build/debug/codecov/X.json" ;;
  "build --show-bin-path") echo "$ROOT/.build/debug" ;;
  *) echo "stub swift: unexpected \$*" >&2; exit 9 ;;
esac
SW
cat > "$ROOT/stubs/llvm-cov" <<'LC'
#!/usr/bin/env bash
cat "$STUB_EXPORT"
LC
cat > "$ROOT/stubs/xcrun" <<'XR'
#!/usr/bin/env bash
if [[ "$1" == "llvm-cov" ]]; then cat "$STUB_EXPORT"; else echo "stub xcrun: unexpected $*" >&2; exit 9; fi
XR
chmod +x "$ROOT/stubs/"*

ALL=(PaywallCore PaywallTesting PaywallKit PaywallCloudSync PaywallSimulator)
CRITICAL=(Journal LedgerEvent Ledger LeaseTable ReservationTable "GateEngine+Draw" CreditReconciler)

# An llvm-cov export: every file at 100 / 100, under $ROOT/Sources/<folder>/. `folder` defaults to the target.
export_for() {  # <out> <targets...>
  local out=$1; shift
  python3 - "$out" "$ROOT" "$@" <<'PY'
import json, sys
out, root, *targets = sys.argv[1:]
critical = ["Journal", "LedgerEvent", "Ledger", "LeaseTable", "ReservationTable", "GateEngine+Draw", "CreditReconciler"]
files = []
for spec in targets:
    target, _, folder = spec.partition("@")
    folder = folder or target
    names = critical if target == "PaywallCore" else ["A"]
    for name in names:
        files.append({"filename": f"{root}/Sources/{folder}/{name}.swift",
                      "summary": {"lines": {"covered": 50, "count": 50}, "regions": {"covered": 20, "count": 20}}})
json.dump({"data": [{"files": files}]}, open(out, "w"))
PY
}

xccov_for() {  # <out> <target> <lines covered> <lines total>
  python3 - "$@" "$ROOT" <<'PY'
import json, sys
out, target, covered, total, root = sys.argv[1:]
json.dump({"targets": [{"name": target, "files": [{"path": f"{root}/Sources/{target}/A.swift",
           "coveredLines": int(covered), "executableLines": int(total)}]}]}, open(out, "w"))
PY
}

baseline_for() {  # <out>
  python3 - "$1" <<'PY'
import json, sys
json.dump({t: {"lines": 100.0, "regions": 100.0} for t in
           ["PaywallCore", "PaywallTesting", "PaywallKit", "PaywallCloudSync", "PaywallSimulator"]}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
}

gate() {  # <export> <args...>; prints the gate's output, returns its exit code
  local export_path=$1; shift
  (cd "$ROOT" && PATH="$ROOT/stubs:$PATH" STUB_EXPORT="$export_path" Scripts/coverage-gate.sh "$@") 2>&1
}

pass=0; fail=0
check() {  # <label> <wanted exit> <actual exit> <output> [grep pattern] [wanted count]
  local label=$1 wanted=$2 actual=$3 out=$4 pattern=${5:-} count=${6:-}
  local ok=1
  [[ "$actual" -eq "$wanted" ]] || ok=0
  if [[ -n "$pattern" ]]; then
    local n; n="$(grep -c -- "$pattern" <<<"$out" || true)"
    if [[ -n "$count" ]]; then [[ "$n" -eq "$count" ]] || ok=0; else [[ "$n" -ge 1 ]] || ok=0; fi
  fi
  if [[ $ok -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "self-test FAILED: $label (exit $actual, wanted $wanted)"; echo "$out"; fi
}

export_for "$ROOT/core-only.json" PaywallCore
export_for "$ROOT/all.json" "${ALL[@]}"
export_for "$ROOT/misplaced.json" "PaywallCore@Core"
export_for "$ROOT/four.json" PaywallCore PaywallTesting PaywallKit PaywallCloudSync
baseline_for "$ROOT/baseline.json"

# (a)
set +e; out="$(gate "$ROOT/core-only.json" --baseline "$ROOT/baseline.json")"; code=$?; set -e
check "(a) a vanished target is missing, not absent" 1 $code "$out" "missing" 4
# (b)
cp "$ROOT/baseline.json" "$ROOT/copy.json"
set +e; out="$(gate "$ROOT/core-only.json" --baseline "$ROOT/baseline.json" --write-baseline "$ROOT/copy.json")"; code=$?; set -e
check "(b) a failed run writes nothing" 1 $code "$out" "missing" 4
cmp -s "$ROOT/baseline.json" "$ROOT/copy.json" && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "self-test FAILED: (b) the copy changed"; }
# (c)
cp "$ROOT/baseline.json" "$ROOT/B.json"
set +e; out="$(gate "$ROOT/all.json" --targets "PaywallCore PaywallTesting" --baseline "$ROOT/B.json" --write-baseline "$ROOT/B.json")"; code=$?; set -e
check "(c) an explicit target list passes and the write-back merges" 0 $code "$out" "passed" 1
python3 - "$ROOT/B.json" <<'PY' && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "self-test FAILED: (c) B lost keys or numbers"; }
import json, sys
b = json.load(open(sys.argv[1]))
assert sorted(b) == ["PaywallCloudSync", "PaywallCore", "PaywallKit", "PaywallSimulator", "PaywallTesting"], b
assert all(v == {"lines": 100.0, "regions": 100.0} for v in b.values()), b
PY
# (d)
set +e; out="$(gate "$ROOT/misplaced.json" --baseline "$ROOT/baseline.json")"; code=$?; set -e
check "(d) misplaced core files leave every critical file without data" 1 $code "$out" "FAIL (no data)" 7
# (e)
set +e; out="$(gate "$ROOT/all.json" --baseline "$ROOT/does-not-exist.json")"; code=$?; set -e
check "(e) a missing baseline is an error" 2 $code "$out" "does not exist"
# (f)
xccov_for "$ROOT/sim-xccov.json" PaywallSimulator 50 50
set +e; out="$(gate "$ROOT/four.json" --xccov "$ROOT/sim-xccov.json" --baseline "$ROOT/baseline.json")"; code=$?; set -e
check "(f) lines-only data for a target with a regions baseline fails, as n/a" 1 $code "$out" "PaywallSimulator regions: n/a" 1
# (g)
set +e; out="$(gate "$ROOT/all.json" --baseline "$ROOT/baseline.json")"; code=$?; set -e
check "(g) the control passes" 0 $code "$out" "passed" 1
# --retire: a renamed target leaves the union and the written file.
cp "$ROOT/baseline.json" "$ROOT/R.json"
set +e; out="$(gate "$ROOT/four.json" --baseline "$ROOT/R.json" --write-baseline "$ROOT/R.json" --retire PaywallSimulator)"; code=$?; set -e
check "(retire) a retired key is neither required nor kept" 0 $code "$out" "passed" 1
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert "PaywallSimulator" not in b and len(b)==4, b' "$ROOT/R.json" \
  && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "self-test FAILED: (retire) the key stayed"; }
# The write-baseline file ratchets on its own, without --baseline.
xccov_for "$ROOT/sim-low.json" PaywallSimulator 40 50
export_for "$ROOT/four-b.json" PaywallCore PaywallTesting PaywallKit PaywallCloudSync
cp "$ROOT/baseline.json" "$ROOT/W.json"
set +e; out="$(gate "$ROOT/four-b.json" --xccov "$ROOT/sim-low.json" --write-baseline "$ROOT/W.json")"; code=$?; set -e
check "(write) the written file is a ratchet too" 1 $code "$out" "PaywallSimulator lines: 80.00% < baseline 100.00%" 1
cmp -s "$ROOT/baseline.json" "$ROOT/W.json" && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "self-test FAILED: (write) W changed on a failed run"; }

echo "coverage-gate self-test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
