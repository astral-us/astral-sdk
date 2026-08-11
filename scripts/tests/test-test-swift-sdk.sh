#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/simulators.json" <<'JSON'
{
  "devices": {
    "com.apple.CoreSimulator.SimRuntime.iOS-25-4": [
      {"name":"iPhone Old","udid":"OLD-UDID","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
      {"name":"iPad Pro","udid":"IPAD-UDID","isAvailable":true},
      {"name":"iPhone 17","udid":"IOS26-UDID","isAvailable":true}
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
      {"name":"iPhone Unavailable","udid":"UNAVAILABLE-UDID","isAvailable":false}
    ]
  }
}
JSON

cat > "$TMP/xcrun" <<'SH'
#!/bin/sh
cat "$SIMULATOR_FIXTURE"
SH

cat > "$TMP/xcodebuild" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$XCODEBUILD_ARGS"
SH

chmod +x "$TMP/xcrun" "$TMP/xcodebuild"
export PATH="$TMP:$PATH"
export SIMULATOR_FIXTURE="$TMP/simulators.json"
export XCODEBUILD_ARGS="$TMP/xcodebuild-args"

actual=$($ROOT/scripts/test-swift-sdk.sh --print-udid)
[ "$actual" = "IOS26-UDID" ] || {
  printf 'expected selected UDID IOS26-UDID, got %s\n' "$actual" >&2
  exit 1
}
[ ! -e "$XCODEBUILD_ARGS" ] || {
  printf '%s\n' '--print-udid unexpectedly invoked xcodebuild' >&2
  exit 1
}

SIM_UDID=OVERRIDE-UDID "$ROOT/scripts/test-swift-sdk.sh" \
  -only-testing:PhroverKitTests/SharedMissionFrameTests -quiet

expected=$(cat <<'ARGS'
test
-scheme
astral-sdk-Package
-destination
id=OVERRIDE-UDID
-only-testing:RoverNavTests
-only-testing:PhroverKitTests
-only-testing:PhroverKitTests/SharedMissionFrameTests
-quiet
ARGS
)
actual=$(cat "$XCODEBUILD_ARGS")
[ "$actual" = "$expected" ] || {
  printf 'unexpected xcodebuild arguments:\n%s\n' "$actual" >&2
  exit 1
}

printf '%s\n' 'test-test-swift-sdk: passed'
