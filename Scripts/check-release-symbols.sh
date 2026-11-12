#!/usr/bin/env bash
# release_archive_has_no_simulator_symbols (App Review 2.3.1(a), 3.1.1): a release build of the shipping
# products contains no simulator, preset, launch-argument, fake or grandfather-override code, and the
# PaywallSimulator module compiles to nothing. The host's archive check runs the same patterns over its .ipa.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release >/dev/null
BIN="$(swift build -c release --show-bin-path)"
FORBIDDEN='PaywallPreset|PaywallSimulat|PaywallLaunchArgument|GrandfatherOverride|grandfatherOverride|FakeStore|FakeClock|FakeConnectivity|simulateBalance|simulateEntitlement'

# Symbol names only: skip the "file.o:" headers nm prints for several files, and blank lines.
symbols() { nm "$@" 2>/dev/null | awk 'NF >= 2 {print $NF}'; }

status=0
for module in PaywallCore PaywallKit PaywallCloudSync; do
  objects=$(find "$BIN" -name "*.o" -path "*${module}*" ! -path "*Tests*")
  [[ -z "$objects" ]] && continue   # Darwin-only modules are absent on Linux
  # shellcheck disable=SC2086
  hits=$(symbols $objects | grep -E "$FORBIDDEN" || true)
  if [[ -n "$hits" ]]; then
    echo "FAIL: $module ships debug-only symbols:"; echo "$hits" | head -20; status=1
  else
    echo "ok: $module"
  fi
done

simulator=$(find "$BIN" -name "*.o" -path "*PaywallSimulator*" ! -path "*Tests*")
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
