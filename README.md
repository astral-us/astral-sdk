# astral-sdk

**Drones that finish the mission when the network doesn't.**

`astral-sdk` is the open Python interface for ArduPilot-based drones used
in the [Astral](https://astral.us) stack. It bundles MAVLink primitives,
camera drivers, and minimal examples so that you can integrate drone
hardware into your own applications without reinventing the boilerplate.

## Install

```bash
uv add astral-sdk
```

or

```bash
pip install astral-sdk
```

Camera support is optional. Pick the drivers you need:

```bash
pip install astral-sdk[camera-oak]        # Luxonis OAK-D Lite
pip install astral-sdk[camera-realsense]  # Intel RealSense D435i
pip install astral-sdk[all]               # both
```

## Quickstart

Copy `src/astral_sdk/config_example.yaml` to `config.yaml` in your working
directory and edit `serial_port` to match your flight controller.

```python
import time
import astral_sdk as drone

# Arm, take off to 2 meters AGL, hover, and land.
if drone.takeoff(2.0):
    time.sleep(5)
    drone.land()

drone.disconnect()
```

All movement commands are clamped to safe limits (see
`MIN_ALTITUDE`, `MAX_ALTITUDE`, `MAX_VELOCITY`, `MAX_YAW_RATE` in
`astral_sdk.drone`). Failsafes can be installed onto the flight controller
once with `astral_sdk.configure_failsafes()`.

See the [`examples/`](./examples) directory for runnable scripts:

- `motor_test.py` — verify motor order and ESC connections.
- `arm_takeoff_land.py` — minimal flight cycle.
- `camera_capture.py` — capture a frame from the onboard camera.
- `sitl/` — run the SDK against simulated ArduPilot, no hardware needed. For the same
  calls exercised against all three supported frames (Copter, Rover, Plane), see
  [`tests/test_e2e_sitl.py`](./tests/test_e2e_sitl.py) — a real, runnable test that
  doubles as a per-vehicle-type usage reference.

## What's included

- **Python SDK** — MAVLink wrappers for arming, takeoff, landing,
  velocity and position control, telemetry, parameters, and failsafe setup.
- **Camera drivers** — common abstraction (`Camera`, `CameraFrame`) plus
  implementations for OAK-D Lite (DepthAI) and Intel RealSense D435i.
- **CLI utilities** — `astral-arm-disarm` and `astral-motor-test`.
- **ROS 2 bridge** — an optional `astral_drone` package under
  `ros2_ws/` that exposes the camera and MAVLink as ROS 2 topics for use
  with Isaac ROS Visual SLAM and Nav2.

## What's not in this repo

The Astral product stack also includes pieces that are intentionally not
open source. To set expectations:

- **Cloud orchestration.** Fleet provisioning, IoT messaging, video
  ingestion, and remote-pilot routing live in our service. They are not
  required to fly with this SDK.
- **On-device VLM stack.** Reasoning loop, vision-language prompts,
  grounding, target selection, and reactive planning are proprietary.
- **Flight hardware.** The companion-computer image, installer scripts,
  and platform integrations ship with our hardware product.

If you need any of those, talk to us at [astral.us](https://astral.us).

## Hardware compatibility

- **Flight controller**: any ArduPilot-compatible board reachable over
  MAVLink. Tested on Cube Orange.
- **Companion computer**: tested on NVIDIA Jetson Orin Nano. macOS and
  generic Linux work for development against SITL.
- **Cameras**: Luxonis OAK-D Lite, Intel RealSense D435i.

## Documentation

Full docs live at [astral.us/docs](https://astral.us/docs).

## License

Apache License 2.0. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

## Status

Early. APIs may change before 1.0. Pin a version in production.
