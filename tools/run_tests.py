#!/usr/bin/env python3
"""Run the pure-Luau test suite outside Roblox.

Shared modules use Roblox-style `require(script.Parent.X)`. This script bundles
every module in src/shared and tests/lib, plus the server's ProfileStore, into one chunk with a tiny
`script`/`require` shim, appends tests/run.luau (or the given test file), and
executes it with the standalone `luau` CLI. Test-only helpers in tests/lib sit
beside the shared modules, so `script.Parent.X` reaches both.

Usage: python3 tools/run_tests.py [path/to/luau] [test file]
"""
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHARED = ROOT / "src" / "shared"
TEST_LIB = ROOT / "tests" / "lib"
# Server modules that take their Roblox services as arguments (ProfileStore).
SERVER_PURE = [ROOT / "src" / "server" / "Services" / "ProfileStore.luau"]
TESTS = ROOT / "tests" / "run.luau"

PRELUDE = """
local __defs, __cache = {}, {}
local __folder = setmetatable({}, { __index = function(_, name) return { __module = name } end })
local function require(ref)
    local name = ref.__module
    if __cache[name] == nil then
        assert(__defs[name], "unknown module " .. tostring(name))
        __cache[name] = __defs[name]({ Parent = __folder })
    end
    return __cache[name]
end
local Shared = __folder
"""


def main() -> int:
    luau = sys.argv[1] if len(sys.argv) > 1 else "luau"
    parts = [PRELUDE]
    for path in sorted(SHARED.glob("*.luau")) + sorted(TEST_LIB.glob("*.luau")) + SERVER_PURE:
        # `export type` is only legal at a chunk's top level, so demote it inside the wrapper.
        source = re.sub(r"^export type ", "type ", path.read_text(), flags=re.M).replace("--!strict", "", 1)
        parts.append(f'__defs["{path.stem}"] = function(script)\n{source}\nend\n')
    tests = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else TESTS
    parts.append("do\n" + tests.read_text() + "\nend\n")
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as handle:
        handle.write("\n".join(parts))
        bundle = handle.name
    return subprocess.call([luau, bundle])


if __name__ == "__main__":
    sys.exit(main())
