#!/usr/bin/env bash
# Coverage gate for ztron-paywall-kit.
#
#   97 % line coverage per target (not per package), and 100 % line + 100 % region coverage on the
#   crash-critical files listed below. Region coverage is reported next to lines and, with --baseline,
#   ratcheted: a change may not lower either number for any target.
#
# Reads two kinds of report and merges them file by file (the better-covered report wins for a file):
#   * llvm-cov export from `swift test --enable-code-coverage` (macOS and Linux). The script runs the export
#     itself over every *.xctest the build produced, because the JSON at `swift test --show-codecov-path`
#     does not always include every test bundle.
#   * `xcrun xccov view --report --json <bundle>.xcresult` from `xcodebuild test -enableCodeCoverage YES`
#     (the simulator lane for PaywallKit, PaywallSimulator and PaywallCloudSync). Lines only.
#
# Usage:
#   swift test --enable-code-coverage
#   Scripts/coverage-gate.sh [--targets "PaywallCore PaywallTesting"] [--xccov report.json]...
#                            [--baseline coverage-baseline.json] [--write-baseline coverage-baseline.json]
#                            [--threshold 97]
#
# Exit status: 0 when every requested target passes, 1 otherwise. No exclusions.
set -euo pipefail

cd "$(dirname "$0")/.."

THRESHOLD=97
TARGETS=""
XCCOV=()
BASELINE=""
WRITE_BASELINE=""

# Crash-critical files: 100 % line and 100 % region. Keep in sync with the design's crash-safety section.
CRITICAL=(
  "Sources/PaywallCore/Journal.swift"
  "Sources/PaywallCore/LedgerEvent.swift"
  "Sources/PaywallCore/Ledger.swift"
  "Sources/PaywallCore/LeaseTable.swift"
  "Sources/PaywallCore/ReservationTable.swift"
  "Sources/PaywallCore/GateEngine+Draw.swift"
  "Sources/PaywallCore/CreditReconciler.swift"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --xccov) XCCOV+=("$2"); shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --write-baseline) WRITE_BASELINE="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "coverage-gate: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [[ "$(uname)" == "Darwin" ]]; then LLVM_COV=(xcrun llvm-cov); else LLVM_COV=(llvm-cov); fi

CODECOV_JSON="$(swift test --show-codecov-path)"
PROFDATA="$(dirname "$CODECOV_JSON")/default.profdata"
if [[ ! -f "$PROFDATA" ]]; then
  echo "coverage-gate: no profile at $PROFDATA; run 'swift test --enable-code-coverage' first" >&2
  exit 2
fi
BIN_PATH="$(swift build --show-bin-path)"

OBJECTS=()
while IFS= read -r bundle; do
  name="$(basename "$bundle" .xctest)"
  if [[ -d "$bundle" ]]; then
    OBJECTS+=("$bundle/Contents/MacOS/$name")
  else
    OBJECTS+=("$bundle")
  fi
done < <(find "$BIN_PATH" -maxdepth 1 -name "*.xctest" | sort)

if [[ ${#OBJECTS[@]} -eq 0 ]]; then
  echo "coverage-gate: no test bundles under $BIN_PATH" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ARGS=("${OBJECTS[0]}")
for object in "${OBJECTS[@]:1}"; do ARGS+=(-object "$object"); done
"${LLVM_COV[@]}" export -summary-only -instr-profile "$PROFDATA" "${ARGS[@]}" \
  -ignore-filename-regex '(\.build|/Tests/|/checkouts/)' > "$WORK/llvm.json"

python3 - "$WORK/llvm.json" "$THRESHOLD" "$TARGETS" "$BASELINE" "$WRITE_BASELINE" "$(pwd)" \
  "${#CRITICAL[@]}" "${CRITICAL[@]}" "${XCCOV[@]+"${XCCOV[@]}"}" <<'PY'
import json, os, sys

llvm_path, threshold, targets_arg, baseline_path, write_baseline, root, n_critical = sys.argv[1:8]
critical = sys.argv[8:8 + int(n_critical)]
xccov_paths = sys.argv[8 + int(n_critical):]
threshold = float(threshold)
root = os.path.realpath(root)

def relative(path):
    path = os.path.realpath(path)
    return os.path.relpath(path, root) if path.startswith(root + os.sep) else None

# file -> {lines: (covered, count), regions: (covered, count) | None}
files = {}

def offer(path, lines, regions):
    rel = relative(path)
    if rel is None or not rel.startswith("Sources/"):
        return
    current = files.get(rel)
    ratio = lambda pair: pair[0] / pair[1] if pair[1] else 1.0
    if current is None or ratio(lines) > ratio(current["lines"]):
        files[rel] = {"lines": lines, "regions": regions if regions is not None else (current or {}).get("regions")}
    elif regions is not None and current.get("regions") is None:
        current["regions"] = regions

for entry in json.load(open(llvm_path))["data"]:
    for f in entry["files"]:
        s = f["summary"]
        offer(f["filename"], (s["lines"]["covered"], s["lines"]["count"]),
              (s["regions"]["covered"], s["regions"]["count"]))

for path in xccov_paths:
    report = json.load(open(path))
    for target in report.get("targets", []):
        for f in target.get("files", []):
            offer(f["path"], (f["coveredLines"], f["executableLines"]), None)

by_target = {}
for rel, data in files.items():
    target = rel.split("/")[1]
    t = by_target.setdefault(target, {"lines": [0, 0], "regions": [0, 0]})
    t["lines"][0] += data["lines"][0]; t["lines"][1] += data["lines"][1]
    if data["regions"]:
        t["regions"][0] += data["regions"][0]; t["regions"][1] += data["regions"][1]

requested = targets_arg.split() if targets_arg.strip() else sorted(by_target)
pct = lambda pair: 100.0 * pair[0] / pair[1] if pair[1] else 100.0
failed = False

print(f"{'target':<20} {'lines':>9} {'regions':>9}   (threshold {threshold:g} % lines)")
summary = {}
for target in requested:
    t = by_target.get(target)
    if t is None:
        print(f"{target:<20} {'missing':>9}            FAIL: no coverage data for this target")
        failed = True
        continue
    lines, regions = pct(t["lines"]), pct(t["regions"])
    summary[target] = {"lines": round(lines, 2), "regions": round(regions, 2)}
    ok = lines + 1e-9 >= threshold
    failed |= not ok
    print(f"{target:<20} {lines:>8.2f}% {regions:>8.2f}%   {'ok' if ok else 'FAIL'}")
    if not ok:
        worst = sorted(((pct(d['lines']), rel, d['lines']) for rel, d in files.items()
                        if rel.split('/')[1] == target and d['lines'][0] < d['lines'][1]))[:8]
        for p, rel, (c, n) in worst:
            print(f"    {rel}: {p:.2f}% ({n - c} lines uncovered)")

print("\ncrash-critical files (100 % lines and regions):")
for rel in critical:
    target = rel.split("/")[1]
    if requested and target not in requested:
        continue
    d = files.get(rel)
    if d is None:
        print(f"  {rel}: FAIL (no data)"); failed = True; continue
    lines = pct(d["lines"]); regions = pct(d["regions"]) if d["regions"] else None
    ok = d["lines"][0] == d["lines"][1] and d["regions"] is not None and d["regions"][0] == d["regions"][1]
    failed |= not ok
    shown = f"{regions:.2f}%" if regions is not None else "n/a"
    print(f"  {rel}: lines {lines:.2f}% regions {shown}  {'ok' if ok else 'FAIL'}")

if baseline_path and os.path.exists(baseline_path):
    baseline = json.load(open(baseline_path))
    print("\nratchet against", baseline_path)
    for target, numbers in summary.items():
        before = baseline.get(target)
        if not before:
            continue
        for kind in ("lines", "regions"):
            if numbers[kind] + 0.01 < before[kind]:
                print(f"  {target} {kind}: {numbers[kind]:.2f}% < baseline {before[kind]:.2f}%  FAIL")
                failed = True

if write_baseline:
    with open(write_baseline, "w") as out:
        json.dump(summary, out, indent=2, sort_keys=True)
        out.write("\n")

print("\ncoverage gate:", "FAILED" if failed else "passed")
sys.exit(1 if failed else 0)
PY
