#!/usr/bin/env bash
# release_archive_has_no_simulator_symbols (App Review 2.3.1(a), 3.1.1).
#
# A release build of the shipping modules (PaywallCore, PaywallKit, PaywallCloudSync) defines no symbol whose raw or
# demangled name mentions the simulator, the presets, the launch arguments, the grandfather override or the fakes, and
# the two debug-only modules (PaywallSimulator, PaywallTesting: every source file is wrapped in `#if DEBUG`) define no
# Swift symbol at all. Every module the platform builds must be present and listable, or the check fails naming it: a
# module that cannot be checked is not a pass.
#
#   Scripts/check-release-symbols.sh              builds `-c release` and checks the release objects
#   Scripts/check-release-symbols.sh --self-test  runs the classifiers over fixture listings, with no build
#
# What it does not do: scan an app archive. A stripped binary keeps few symbols, so a host app's archive check is the
# host's own, not a rerun of these patterns.
set -euo pipefail
cd "$(dirname "$0")/.."

FORBIDDEN='PaywallPreset|PaywallSimulat|PaywallLaunchArgument|GrandfatherOverride|grandfatherOverride|FakeStore|FakeClock|FakeConnectivity|FakePromotionalOfferSigner|simulateBalance|simulateEntitlement'
SHIPPING=(PaywallCore PaywallKit PaywallCloudSync)
EMPTY=(PaywallSimulator PaywallTesting)
# Names a debug-only module legitimately carries in release: the reflection version marker and the force-load
# symbols, which spell the module's own name.
ALLOWED_IN_EMPTY='^_*swift_reflection_version$|^_*_swift_FORCE_LOAD_\$_|^_*swift_FORCE_LOAD_\$_'

# The demangler: `swift-demangle` next to the toolchain's swiftc (Darwin and Linux), or through xcrun on Darwin.
find_demangler() {
  local candidate
  candidate="$(dirname "$(command -v swiftc 2>/dev/null || echo /nonexistent)")/swift-demangle"
  if [[ -x "$candidate" ]]; then echo "$candidate"; return; fi
  if command -v swift-demangle >/dev/null 2>&1; then echo swift-demangle; return; fi
  if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then echo "xcrun swift-demangle"; return; fi
  echo "check-release-symbols: FAIL: no swift-demangle in this toolchain" >&2
  exit 2
}
DEMANGLE="${DEMANGLE:-$(find_demangler)}"

# Symbol names from nm lines on stdin: the last field of every line with at least two fields, so the "file.o:" headers
# nm prints for several files, and blank lines, go. `defined_names` keeps only lines that start with an address.
names() { awk 'NF >= 2 {print $NF}'; }
defined_names() { awk 'NF >= 3 && $1 ~ /^[0-9a-fA-F]+$/ {print $NF}'; }

# The raw names and their demangled forms, one per line.
with_demangled() { local raw; raw="$(cat)"; [[ -z "$raw" ]] && return 0; printf '%s\n' "$raw"; printf '%s\n' "$raw" | $DEMANGLE; }

# A shipping module's verdict, from nm lines on stdin.
check_shipping() {  # <module>
  local raw hits
  raw="$(names)"
  if [[ -z "$raw" ]]; then echo "FAIL: $1: the listing has no symbols"; return 1; fi
  hits="$(printf '%s\n' "$raw" | with_demangled | grep -E "$FORBIDDEN" | sort -u || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL: $1 ships debug-only symbols:"; echo "$hits" | head -20; return 1
  fi
  echo "ok: $1"
}

# A debug-only module's verdict, from nm lines on stdin: no defined Swift symbol, and nothing forbidden beyond the
# names every module carries.
check_empty() {  # <module>
  local all defined hits
  all="$(cat)"
  defined="$(printf '%s\n' "$all" | defined_names | grep -E '^_?\$s' || true)"
  if [[ -n "$defined" ]]; then
    echo "FAIL: $1 is not empty in release (defines Swift symbols):"; echo "$defined" | head -20; return 1
  fi
  hits="$(printf '%s\n' "$all" | names | grep -Ev "$ALLOWED_IN_EMPTY" | with_demangled | grep -E "$FORBIDDEN" | sort -u || true)"
  if [[ -n "$hits" ]]; then
    echo "FAIL: $1 carries debug-only names:"; echo "$hits" | head -20; return 1
  fi
  echo "ok: $1 compiles to nothing"
}

is_empty_module() { printf '%s\n' "${EMPTY[@]}" | grep -qx "$1"; }

# One module under <bin>: find its objects (`<Module>.build/*.o`, or one `<Module>.o` next to the products, anchored
# on the module's own name, never a bare substring the checkout's path could contain), list them, classify.
check_module() {  # <module> <bin>
  local module=$1 bin=$2 objects listing
  objects="$(find "$bin" -name "*.o" \( -path "*/$module.build/*" -o -name "$module.o" \) 2>/dev/null || true)"
  if [[ -z "$objects" ]]; then echo "FAIL: $module: no release objects under $bin"; return 1; fi
  # shellcheck disable=SC2086
  if ! listing="$(nm $objects 2>&1)"; then echo "FAIL: $module: nm failed: ${listing:-no output}"; return 1; fi
  if is_empty_module "$module"; then check_empty "$module" <<<"$listing"; else check_shipping "$module" <<<"$listing"; fi
}

expected_modules() {
  if [[ "$(uname)" == "Darwin" ]]; then printf '%s\n' "${SHIPPING[@]}" "${EMPTY[@]}"; else printf '%s\n' PaywallCore PaywallTesting; fi
}

self_test() {
  local work pass=0 fail=0
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  mkdir -p "$work/stubs"
  # A stub nm prints the fixture named by NM_FIXTURE, or fails when NM_FAIL is set.
  cat > "$work/stubs/nm" <<'NM'
#!/usr/bin/env bash
if [[ -n "${NM_FAIL:-}" ]]; then echo "nm: cannot read object" >&2; exit 1; fi
cat "$NM_FIXTURE"
NM
  chmod +x "$work/stubs/nm"
  expect() {  # <expected exit> <description> <module> <fixture or -> [NM_FAIL]
    local wanted=$1 label=$2 module=$3 fixture=$4 bin out code
    bin="$work/bin-$RANDOM$RANDOM"
    mkdir -p "$bin/$module.build"
    [[ "$fixture" != "-" ]] && : > "$bin/$module.build/a.o"
    set +e
    out="$(PATH="$work/stubs:$PATH" NM_FIXTURE="$fixture" NM_FAIL="${5:-}" check_module "$module" "$bin" 2>&1)"
    code=$?
    set -e
    if [[ "$code" -eq "$wanted" ]] && { [[ "$wanted" -eq 0 ]] || grep -q "FAIL: $module" <<<"$out"; }; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1)); echo "self-test FAILED: $label (exit $code, wanted $wanted)"; echo "$out"
    fi
  }
  # Fixtures in nm's shape. The three leaks the review used: an extension method on a PaywallKit type, one on a
  # PaywallCore type, and a static factory returning a FakeStore-backed configuration.
  printf '%s\n' '0000000000000000 T _$s10PaywallKit0A15ServiceProviderC0A9SimulatorE22grantEverythingForDemoSbyF' > "$work/leak1"
  printf '%s\n' '0000000000000000 T _$s11PaywallCore10GateEngineC0A9SimulatorE15simulatorUnlockSiyF' > "$work/leak2"
  printf '%s\n' '0000000000000000 T _$s10PaywallKit0A0C13ConfigurationV0A9SimulatorE17b3v2DemoFakeStore7catalogAE0A4Core14ProductCatalogV_tFZ' > "$work/leak3"
  printf '%s\n' '0000000000000000 S ___swift_reflection_version' '                 U __swift_FORCE_LOAD_$_swiftCompatibility56' \
    '0000000000000000 S __swift_FORCE_LOAD_$_swiftCompatibility56_$_PaywallSimulator' > "$work/clean-empty"
  printf '%s\n' '0000000000000000 S ___swift_reflection_version' \
    '0000000000000000 S __swift_FORCE_LOAD_$_swiftCompatibility56_$_PaywallTesting' > "$work/clean-testing"
  printf '%s\n' '0000000000000000 T _$s14PaywallTesting9FakeStoreC12setReachableyySbF' > "$work/leak-testing"
  # A shipping module: a preset reference the raw name hides behind a word substitution (demangled, it reads
  # `PaywallKit.b3v2ApplyPaywallPreset`), and a string literal that spells it.
  printf '%s\n' '0000000000000000 T _$s10PaywallKit09b3v2ApplyA6PresetSiyF' > "$work/leak-demangled"
  printf '%s\n' '0000000000000000 s l_.str.13.PaywallPreset' > "$work/leak-string"
  printf '%s\n' '0000000000000000 T _$s10PaywallKit0A0C9configureyyAC13ConfigurationVF' '                 U _$s11PaywallCore10GateEngineCMa' \
    '0000000000000000 s l_.str.14.ztron.paywall' > "$work/clean-kit"
  : > "$work/empty-listing"

  expect 1 "PaywallSimulator fails on a leaked PaywallKit extension" PaywallSimulator "$work/leak1"
  expect 1 "PaywallSimulator fails on a leaked PaywallCore extension" PaywallSimulator "$work/leak2"
  expect 1 "PaywallSimulator fails on a leaked fake-backed factory" PaywallSimulator "$work/leak3"
  expect 0 "PaywallSimulator passes the unmodified tree's listing" PaywallSimulator "$work/clean-empty"
  expect 1 "PaywallTesting fails on a defined fake" PaywallTesting "$work/leak-testing"
  expect 0 "PaywallTesting passes its empty listing" PaywallTesting "$work/clean-testing"
  expect 1 "PaywallKit fails on a preset reachable only through demangling" PaywallKit "$work/leak-demangled"
  expect 1 "PaywallKit fails on a preset string literal" PaywallKit "$work/leak-string"
  expect 0 "PaywallKit passes a clean listing" PaywallKit "$work/clean-kit"
  expect 1 "a shipping module with an empty listing fails" PaywallCore "$work/empty-listing"
  expect 1 "a missing expected module fails, named" PaywallCloudSync "-"
  expect 1 "an nm failure fails, named" PaywallCore "$work/clean-kit" 1
  echo "self-test: $pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)"
status=0
while IFS= read -r module; do
  check_module "$module" "$BIN" || status=1
done < <(expected_modules)
exit $status
