# SITL (Software-In-The-Loop) example

Run the Astral SDK against a simulated ArduPilot copter — no drone, no GPU.

## What you'll need

- Python 3.10+ (already required by `astral-sdk`)
- ArduPilot SITL: see <https://ardupilot.org/dev/docs/sitl-with-gazebo.html> for
  the canonical setup. The minimum is `sim_vehicle.py` from the ArduPilot tree.

## Start the simulator

In one terminal:

```bash
sim_vehicle.py -v ArduCopter --console --map
```

This opens a MAVLink TCP listener on `127.0.0.1:5760` by default.

## Talk to it from the SDK

In another terminal:

```bash
export ASTRAL_SDK_SERIAL_PORT=tcp:127.0.0.1:5760
python fly_sitl.py
```

`fly_sitl.py` is a minimal arm/takeoff/hover/land that uses the same SDK
calls you'd run on real hardware — the only thing that changes is the
`ASTRAL_SDK_SERIAL_PORT` env var.

## Why this works

`astral_sdk.drone._connect()` recognizes URLs starting with `tcp:`, `udp:`,
or `udpin:` and skips the serial-device check. Everything downstream
(arm, takeoff, velocity commands, telemetry) is pymavlink under the hood
and is transport-agnostic.

## Next step

For a perception-in-the-loop sim with cameras, ROS 2, and Nav2, see the
[Isaac Sim guide](https://astral.us/docs/isaac-sim).
