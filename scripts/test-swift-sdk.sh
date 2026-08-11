#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

select_udid() {
  xcrun simctl list devices available -j | python3 -c '
import json
import re
import sys

devices = json.load(sys.stdin).get("devices", {})
for runtime, entries in devices.items():
    match = re.search(r"iOS(?:-|\s)(\d+)", runtime)
    if match is None or int(match.group(1)) < 26:
        continue
    for device in entries:
        if device.get("isAvailable") and "iPhone" in device.get("name", ""):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("no available iOS 26+ iPhone simulator found")
'
}

UDID=${SIM_UDID:-}
if [ -z "$UDID" ]; then
  UDID=$(select_udid)
fi

if [ "${1:-}" = "--print-udid" ]; then
  printf '%s\n' "$UDID"
  exit 0
fi

cd "$ROOT"
exec xcodebuild test \
  -scheme astral-sdk-Package \
  -destination "id=$UDID" \
  -only-testing:RoverNavTests \
  -only-testing:PhroverKitTests \
  "$@"
