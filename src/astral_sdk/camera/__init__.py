"""
Camera module with auto-detection for supported cameras.

Supports:
- Luxonis OAK-D Lite (DepthAI)
- Intel RealSense D435i

See https://astral.us/docs for details.
"""

from astral_sdk.camera.base import Camera, CameraFrame
from astral_sdk.camera.auto import get_camera, list_available_cameras

__all__ = ["Camera", "CameraFrame", "get_camera", "list_available_cameras"]
