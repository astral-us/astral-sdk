import os
from glob import glob

from setuptools import setup

package_name = "astral_drone"

setup(
    name=package_name,
    version="0.1.0",
    packages=[package_name],
    data_files=[
        ("share/ament_index/resource_index/packages",
            ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        (os.path.join("share", package_name, "launch"), glob("launch/*.py")),
        (os.path.join("share", package_name, "config"), glob("config/*.yaml")),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="Astral AI",
    maintainer_email="team@astral.us",
    description="ROS 2 integration for astral-sdk: camera bridge, MAVLink bridge, Nav2 stack.",
    license="Apache-2.0",
    tests_require=["pytest"],
    entry_points={
        "console_scripts": [
            "camera_node = astral_drone.camera_node:main",
            "mavlink_bridge = astral_drone.mavlink_bridge:main",
        ],
    },
)
