#!/usr/bin/env bash
# release_archive_has_no_simulator_symbols (App Review 2.3.1(a), 3.1.1): a release build of the shipping
# products contains no simulator, preset, launch-argument, fake or grandfather-override code, and the
# PaywallSimulator module compiles to nothing. The host's archive check runs the same patterns over its .ipa.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)"
FORBIDDEN='PaywallPreset|PaywallSimulat|PaywallLaunchArgument|GrandfatherOverride|grandfatherOverride|FakeStore|FakeClock|FakeConnectivity|FakePromotionalOfferSigner|simulateBalance|simulateEntitlement'

# Symbol names only: skip the "file.o:" headers nm prints for several files, and blank lines.
symbols() { nm "$@" 2>/dev/null | awk 'NF >= 2 {print $NF}'; }

# A module's own object files under either layout the toolchains produce: `<Module>.build/*.o`, or one `<Module>.o`
# next to the products (Xcode 27's swift-build). Anchored on the module's directory or file name, never on a bare
# substring, which the checkout's own path can contain (`.../ZTronPaywallKit/.build/...` matches "*PaywallKit*").
module_objects() { find "$BIN" -name "*.o" \( -path "*/$1.build/*" -o -name "$1.o" \); }

status=0
for module in PaywallCore PaywallKit PaywallCloudSync; do
  objects=$(module_objects "$module")
  [[ -z "$objects" ]] && continue   # Darwin-only modules are absent on Linux
  # shellcheck disable=SC2086
  hits=$(symbols $objects | grep -E "$FORBIDDEN" || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: $module ships debug-only symbols:"; echo "$hits" | head -20; status=1
  else
    echo "ok: $module"
  fi
done

simulator=$(module_objects PaywallSimulator)
if [[ -n "$simulator" ]]; then
  # shellcheck disable=SC2086
  hits=$(symbols $simulator | grep -E '^_?\$s16PaywallSimulator' || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: PaywallSimulator is not empty in release:"; echo "$hits" | head -20; status=1
  else
    echo "ok: PaywallSimulator compiles to nothing"
  fi
fi
exit $status
