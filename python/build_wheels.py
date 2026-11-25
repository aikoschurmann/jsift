"""Cross-compiles libjsift with Zig and builds one wheel per platform, plus the sdist.

Usage: python python/build_wheels.py [--out dist]

Needs `zig` (0.16) on PATH and `pip install build`. Each wheel is tagged py3-none-<platform>:
the library uses only the C ABI, so a single wheel serves every Python 3 version.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (zig target, wheel platform tag). glibc 2.17 is the manylinux2014 baseline.
TARGETS = [
    ("x86_64-linux-gnu.2.17", "manylinux_2_17_x86_64"),
    ("aarch64-linux-gnu.2.17", "manylinux_2_17_aarch64"),
    ("x86_64-linux-musl", "musllinux_1_2_x86_64"),
    ("aarch64-linux-musl", "musllinux_1_2_aarch64"),
    ("aarch64-macos.11.0", "macosx_11_0_arm64"),
    ("x86_64-macos.11.0", "macosx_11_0_x86_64"),
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="dist")
    args = parser.parse_args()
    out = (ROOT / args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)

    for zig_target, plat in TARGETS:
        print(f"==> {zig_target} -> {plat}", flush=True)
        # A stale build/lib would carry the previous platform's library into this wheel.
        shutil.rmtree(ROOT / "build" / "lib", ignore_errors=True)
        env = {**os.environ, "JSIFT_ZIG_TARGET": zig_target, "JSIFT_PLAT_NAME": plat}
        subprocess.check_call(
            [sys.executable, "-m", "build", "--wheel", "--no-isolation", "--outdir", str(out)],
            cwd=ROOT,
            env=env,
        )

    print("==> sdist", flush=True)
    subprocess.check_call([sys.executable, "-m", "build", "--sdist", "--outdir", str(out)], cwd=ROOT)


if __name__ == "__main__":
    main()
