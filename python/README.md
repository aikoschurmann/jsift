# jsift

Python bindings for [jsift](https://github.com/aikoschurmann/jsift), a blisteringly fast JSONL
search engine written in Zig. A SIMD search over the raw bytes skips every line that can't
match, a validating JSON parser decides the rest exactly, and large inputs are scanned on
all cores. It is 85–200x faster than `jaq` on 8 cores (20–65x on one), and the results
are exact.

```bash
pip install jsift
```

The search runs in-process in native code, with the GIL released. Nothing runs as a
subprocess. Large inputs are scanned on one thread per CPU, up to 8; pass `threads=` to
any function to change that (`threads=1` for one). The result is the same either way.

```python
import jsift

# Matching lines, parsed
jsift.search("level eq error AND status gte 500", file="app.jsonl")
# -> [{"level": "error", "status": 503, ...}, ...]

# Count only
jsift.count("level eq error", file="app.jsonl")          # -> 1234

# Pull out fields, or aggregate
jsift.select("service,latency_ms WHERE status eq 200", file="app.jsonl")
jsift.search("SELECT service,avg:latency_ms WHERE status eq 200", file="app.jsonl")

# Data already in memory (bytes or str)
jsift.search("user.id in 1,2,3", data=b'{"user": {"id": 2}}\n')

# Raw matching lines without parsing them (fastest)
jsift.search_lines("level eq error", file="app.jsonl", limit=100)

# Byte-level matching only: faster, approximate
jsift.count("level eq error", file="app.jsonl", fast=True)

# Low level: exactly the CLI's output, in any format
jsift.run("SELECT name,age", file="people.jsonl", format="csv", header=True).output
```

A query is a string, split the way a shell splits a command line, or a list of tokens. The
language is the same as the CLI's:

| | |
|---|---|
| Operators | `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `has`, `exists`, `in` |
| Logic | `AND`, `OR` (AND binds tighter), `NOT`, parentheses: `(a eq 1 OR b eq 2) AND c exists` |
| Paths | `user.id` for nested keys, `a\.b` for a literal dot |
| Types | auto-detected; force with `s:` (string), `n:` (number), `b:true` |
| Aggregations | `count:f`, `sum:f`, `min:f`, `max:f`, `avg:f`, per group with `GROUP BY f` |

An invalid query, or a file that can't be read, raises `jsift.JsiftError`.

Wheels are available for Linux (x86_64 and aarch64, glibc and musl) and macOS (arm64 and
x86_64). They work on every Python version from 3.9 up.
