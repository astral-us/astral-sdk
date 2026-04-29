"""Smoke tests: verify the public API imports cleanly."""


def test_import_top_level():
    import astral_sdk
    assert astral_sdk.__version__


def test_public_api_surface():
    import astral_sdk
    expected = {
        "arm", "disarm", "takeoff", "land", "goto",
        "set_velocity", "set_yaw", "wait",
        "get_position", "get_attitude", "get_battery",
        "get_flight_mode", "get_telemetry", "is_armed",
        "motor_test", "configure_battery_monitoring",
        "configure_failsafes", "setup_drone",
        "capture_photo", "release_camera",
        "set_config_path", "disconnect",
        "MAX_VELOCITY", "MAX_ALTITUDE", "MIN_ALTITUDE", "MAX_YAW_RATE",
    }
    for name in expected:
        assert hasattr(astral_sdk, name), f"Missing public symbol: {name}"


def test_drone_module_importable():
    from astral_sdk import drone
    assert drone.MAX_VELOCITY == 5.0
    assert drone.MIN_ALTITUDE < drone.MAX_ALTITUDE


def test_camera_base_importable():
    # The base class has no hardware deps; should import without depthai/pyrealsense2.
    from astral_sdk.camera.base import Camera, CameraFrame
    assert Camera.CAMERA_TYPE == "unknown"
    frame = CameraFrame()
    assert frame.rgb is None
    assert frame.depth is None


def test_camera_auto_importable():
    # auto module shouldn't require either camera SDK to be installed.
    from astral_sdk.camera.auto import list_available_cameras, get_camera
    # list_available_cameras should not raise even without hardware
    cams = list_available_cameras()
    assert isinstance(cams, list)
    # get_camera should return None when nothing is available
    assert get_camera() is None or hasattr(get_camera(), "CAMERA_TYPE")


def test_arm_disarm_module_importable():
    # CLI script should import cleanly.
    from astral_sdk import arm_disarm
    assert callable(arm_disarm.main)


def test_motor_test_module_importable():
    from astral_sdk import motor_test as mt
    assert callable(mt.run_motor_test)
