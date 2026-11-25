"""Python bindings for jsift, a fast JSONL search engine.

The query language is the same as the CLI's::

    import jsift

    jsift.search("level eq error AND status gte 500", file="app.jsonl")
    jsift.count("level eq error", file="app.jsonl")
    jsift.select("SELECT service,avg:latency_ms WHERE status eq 200", file="app.jsonl")

Input is either ``file=`` (a path, read by jsift's own threaded reader) or ``data=``
(``bytes``/``str`` of JSONL already in memory). The search runs in native code with the
GIL released, so other Python threads keep running.
"""

from __future__ import annotations

import ctypes
import json
import os
import shlex
from dataclasses import dataclass
from typing import Any, Sequence, Union

from ._lib import _JsiftResult, lib

__all__ = ["JsiftError", "Result", "run", "search", "search_lines", "count", "select", "__version__"]

__version__: str = lib.jsift_version().decode()

Query = Union[str, Sequence[str]]
PathLike = Union[str, "os.PathLike[str]"]
Data = Union[bytes, bytearray, memoryview, str]


class JsiftError(ValueError):
    """Raised for an invalid query, or when the input can't be read."""


@dataclass(frozen=True)
class Result:
    """Raw output of a query: exactly what the CLI would print, plus the match count."""

    output: bytes
    matched: int

    def lines(self) -> list[bytes]:
        return self.output.splitlines()


def _tokens(query: Query) -> list[str]:
    return shlex.split(query) if isinstance(query, str) else list(query)


def run(
    query: Query,
    *,
    file: PathLike | None = None,
    data: Data | None = None,
    limit: int | None = None,
    fast: bool = False,
    invert: bool = False,
    format: str | None = None,
    count_only: bool = False,
    header: bool = False,
) -> Result:
    """Runs a query and returns the raw output.

    ``query`` is a string (split like a shell command line) or a list of CLI tokens.
    Exactly one of ``file`` and ``data`` must be given.
    """
    if (file is None) == (data is None):
        raise TypeError("pass exactly one of file= or data=")

    args = _tokens(query)
    if limit is not None:
        if limit < 0:
            raise ValueError("limit must be non-negative")
        args = ["--limit", str(limit), *args]
    if format is not None:
        args = ["--format", format, *args]
    if fast:
        args = ["--fast", *args]
    if invert:
        args = ["--invert", *args]
    if count_only:
        args = ["--count", *args]
    if header:
        args = ["--header", *args]

    encoded = [arg.encode() for arg in args]
    argv = (ctypes.c_char_p * max(len(encoded), 1))(*encoded)

    path_arg: bytes | None = None
    buf: bytes | None = None
    if file is not None:
        path_arg = os.fsencode(file)
    else:
        if isinstance(data, str):
            buf = data.encode()
        else:
            buf = bytes(data)  # type: ignore[arg-type]

    result = _JsiftResult()
    status = lib.jsift_query(
        argv, len(encoded), path_arg, buf, len(buf) if buf is not None else 0, ctypes.byref(result)
    )
    try:
        if status != 0:
            message = result.error_message.decode() if result.error_message else "unknown error"
            if file is not None:
                message = f"{os.fsdecode(file)}: {message}"
            raise JsiftError(message)
        output = ctypes.string_at(result.output, result.output_len) if result.output_len else b""
        return Result(output=output, matched=result.matched)
    finally:
        lib.jsift_free_result(ctypes.byref(result))


def search_lines(
    query: Query,
    *,
    file: PathLike | None = None,
    data: Data | None = None,
    limit: int | None = None,
    fast: bool = False,
    invert: bool = False,
) -> list[bytes]:
    """Returns the matching lines as raw bytes, without parsing them."""
    return run(query, file=file, data=data, limit=limit, fast=fast, invert=invert).lines()


def search(
    query: Query,
    *,
    file: PathLike | None = None,
    data: Data | None = None,
    limit: int | None = None,
    fast: bool = False,
    invert: bool = False,
) -> list[Any]:
    """Returns the matching lines parsed as JSON.

    For a ``SELECT`` query, each item is a dict of the selected fields; with aggregations
    the list holds a single dict.
    """
    result = run(query, file=file, data=data, limit=limit, fast=fast, invert=invert, format="json")
    return [json.loads(line) for line in result.lines()]


def select(
    query: Query,
    *,
    file: PathLike | None = None,
    data: Data | None = None,
    limit: int | None = None,
    fast: bool = False,
    invert: bool = False,
) -> list[dict[str, Any]]:
    """Alias of :func:`search` for ``SELECT`` queries; ``SELECT`` is prepended if missing."""
    tokens = _tokens(query)
    if not tokens or tokens[0].lower() != "select":
        tokens = ["SELECT", *tokens]
    return search(tokens, file=file, data=data, limit=limit, fast=fast, invert=invert)


def count(
    query: Query = (),
    *,
    file: PathLike | None = None,
    data: Data | None = None,
    fast: bool = False,
    invert: bool = False,
) -> int:
    """Returns the number of matching lines (all lines when the query is empty)."""
    return run(query, file=file, data=data, fast=fast, invert=invert, count_only=True).matched
