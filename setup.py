"""Builds libjsift with Zig and bundles it into the `jsift` package.

Environment variables (all optional):
  JSIFT_ZIG_TARGET  Zig target to cross-compile for, e.g. x86_64-linux-gnu.2.17
  JSIFT_PLAT_NAME   Wheel platform tag to use, e.g. manylinux_2_17_x86_64
  ZIG             Path to the zig executable (default: "zig" on PATH)

Without them the library is built for (and the wheel tagged for) the current machine.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

from setuptools import Distribution, setup
from setuptools.command.build_py import build_py
from wheel.bdist_wheel import bdist_wheel

ROOT = Path(__file__).resolve().parent


def read_version() -> str:
    zon = (ROOT / "build.zig.zon").read_text()
    return re.search(r'\.version\s*=\s*"([^"]+)"', zon).group(1)


def lib_filename(target: str) -> str:
    if "windows" in target:
        return "jsift.dll"
    if "macos" in target or (not target and os.uname().sysname == "Darwin"):
        return "libjsift.dylib"
    return "libjsift.so"


class BuildPyWithZig(build_py):
    def run(self):
        super().run()
        target = os.environ.get("JSIFT_ZIG_TARGET", "")
        zig = os.environ.get("ZIG", "zig")
        prefix = (ROOT / "build" / "zig-out" / (target or "native")).resolve()
        cmd = [zig, "build", "lib", "-Doptimize=ReleaseFast", "--prefix", str(prefix)]
        if target:
            cmd.append(f"-Dtarget={target}")
        subprocess.check_call(cmd, cwd=ROOT)

        name = lib_filename(target)
        built = prefix / ("bin" if name.endswith(".dll") else "lib") / name
        dest = Path(self.build_lib) / "jsift"
        dest.mkdir(parents=True, exist_ok=True)
        # Only one native library per wheel.
        for stale in ("libjsift.so", "libjsift.dylib", "jsift.dll"):
            (dest / stale).unlink(missing_ok=True)
        shutil.copy2(built, dest / name)


class BinaryDistribution(Distribution):
    """Marks the package as platform-specific, so the wheel installs into platlib."""

    def has_ext_modules(self):
        return True


class PlatformWheel(bdist_wheel):
    """The library doesn't use the CPython ABI: one wheel per platform fits every Python 3."""

    def finalize_options(self):
        super().finalize_options()
        plat = os.environ.get("JSIFT_PLAT_NAME")
        if plat:
            self.plat_name = plat
            self.plat_name_supplied = True

    def get_tag(self):
        _, _, plat = super().get_tag()
        return "py3", "none", plat


setup(
    version=read_version(),
    distclass=BinaryDistribution,
    cmdclass={"build_py": BuildPyWithZig, "bdist_wheel": PlatformWheel},
)
