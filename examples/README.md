# Examples

Runnable examples that demonstrate `astral-sdk`.

## Setup

```bash
uv add astral-sdk
# or:
pip install astral-sdk
```

For the camera example, install one of the camera extras:

```bash
pip install astral-sdk[camera-oak]        # OAK-D Lite
pip install astral-sdk[camera-realsense]  # Intel RealSense D435i
pip install astral-sdk[all]               # Both
```

Copy `src/astral_sdk/config_example.yaml` to `config.yaml` in the directory
you run the example from, and edit `serial_port` to match your flight
controller (a stable `/dev/serial/by-id/...` path is recommended over
`/dev/ttyACM*`).

## Examples

- `motor_test.py` — Spin each motor in turn (props off!).
- `arm_takeoff_land.py` — Minimal flight cycle: arm, take off to 2 m, hover, land.
- `camera_capture.py` — Capture a single frame from an OAK-D Lite or RealSense.

## Safety

Every flight example runs against real hardware. Read the source before
running and keep manual override available.
