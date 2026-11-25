"""ctypes loader for the bundled libjsift shared library."""

from __future__ import annotations

import ctypes
import os
import sys
from pathlib import Path


class _JsiftResult(ctypes.Structure):
    _fields_ = [
        ("output", ctypes.POINTER(ctypes.c_char)),
        ("output_len", ctypes.c_size_t),
        ("matched", ctypes.c_size_t),
        ("error_message", ctypes.c_char_p),
    ]


def _lib_filename() -> str:
    if sys.platform == "darwin":
        return "libjsift.dylib"
    if sys.platform == "win32":
        return "jsift.dll"
    return "libjsift.so"


def _load() -> ctypes.CDLL:
    # JSIFT_LIBRARY overrides the bundled copy (handy while developing the Zig side).
    path = os.environ.get("JSIFT_LIBRARY") or str(Path(__file__).with_name(_lib_filename()))
    try:
        lib = ctypes.CDLL(path)
    except OSError as exc:
        raise ImportError(
            f"jsift: could not load the native library at {path}. "
            "No wheel may exist for this platform; build from source with Zig 0.16 installed."
        ) from exc

    lib.jsift_version.restype = ctypes.c_char_p
    lib.jsift_version.argtypes = []
    lib.jsift_query.restype = ctypes.c_int
    lib.jsift_query.argtypes = [
        ctypes.POINTER(ctypes.c_char_p),
        ctypes.c_size_t,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.POINTER(_JsiftResult),
    ]
    lib.jsift_free_result.restype = None
    lib.jsift_free_result.argtypes = [ctypes.POINTER(_JsiftResult)]
    return lib


lib = _load()
