#!/usr/bin/env python3
"""Emit a Luau chunk that mirrors the Rojo project into an open Studio place.

For use without the Rojo plugin (e.g. through Studio's "run Luau" tooling):
paste the output into Studio's command bar or an execute-Luau call. It creates
missing folders/remotes/scripts from default.project.json and overwrites each
script's Source with the file on disk. It never deletes anything.

Usage: python3 tools/studio_sync.py [--github OWNER/REPO@REF] [substring filter ...] > sync.luau

With --github, the chunk downloads each file from raw.githubusercontent.com at
REF instead of embedding it, which keeps it small. It turns HttpService on for
the download and restores the previous setting afterwards.
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

lines = [
    "local function child(parent, name, className)",
    "\tlocal found = parent:FindFirstChild(name)",
    "\tif found and found.ClassName ~= className then found:Destroy(); found = nil end",
    "\tif not found then found = Instance.new(className); found.Name = name; found.Parent = parent end",
    "\treturn found",
    "end",
    "local count = 0",
]
args = sys.argv[1:]
github = None
if args[:1] == ["--github"]:
    github = args[1]
    args = args[2:]
filters = args


def long_string(text: str) -> str:
    level = 0
    while ("]" + "=" * level + "]") in text:
        level += 1
    eq = "=" * level
    return f"[{eq}[\n{text}]{eq}]"


def script_class(path: pathlib.Path) -> tuple[str, str]:
    name = path.name
    if name.endswith(".server.luau"):
        return name[: -len(".server.luau")], "Script"
    if name.endswith(".client.luau"):
        return name[: -len(".client.luau")], "LocalScript"
    return path.stem, "ModuleScript"


def emit_dir(var: str, directory: pathlib.Path, counter: list) -> None:
    for entry in sorted(directory.iterdir()):
        if entry.is_dir():
            counter[0] += 1
            sub = f"d{counter[0]}"
            lines.append(f'local {sub} = child({var}, "{entry.name}", "Folder")')
            emit_dir(sub, entry, counter)
        elif entry.suffix == ".luau":
            rel = str(entry.relative_to(ROOT))
            if filters and not any(f in rel for f in filters):
                continue
            name, cls = script_class(entry)
            if github:
                source = f'fetch("{rel}")'
            else:
                source = long_string(entry.read_text())
            lines.append(f'child({var}, "{name}", "{cls}").Source = {source}')
            lines.append("count += 1")


def emit_node(var: str, node: dict, counter: list) -> None:
    if "$path" in node:
        emit_dir(var, ROOT / node["$path"], counter)
    for key, value in node.items():
        if key.startswith("$"):
            continue
        counter[0] += 1
        sub = f"n{counter[0]}"
        if "$className" in value:
            lines.append(f'local {sub} = child({var}, "{key}", "{value["$className"]}")')
        else:
            # No class given: reuse whatever exists (e.g. StarterPlayerScripts), else a Folder.
            lines.append(f'local {sub} = {var}:FindFirstChild("{key}") or child({var}, "{key}", "Folder")')
        emit_node(sub, value, counter)


def main() -> None:
    if github:
        repo, ref = github.split("@")
        lines.extend([
            'local HttpService = game:GetService("HttpService")',
            "local wasEnabled = HttpService.HttpEnabled",
            "HttpService.HttpEnabled = true",
            "local function fetch(path)",
            f'\tlocal ok, body = pcall(HttpService.GetAsync, HttpService, "https://raw.githubusercontent.com/{repo}/{ref}/" .. path, true)',
            "\tif not ok then HttpService.HttpEnabled = wasEnabled; error(path .. \": \" .. tostring(body)) end",
            "\treturn body",
            "end",
        ])
    project = json.loads((ROOT / "default.project.json").read_text())
    counter = [0]
    for service, node in project["tree"].items():
        if service.startswith("$"):
            continue
        counter[0] += 1
        var = f"s{counter[0]}"
        lines.append(f'local {var} = game:GetService("{service}")')
        emit_node(var, node, counter)
    if github:
        lines.append("HttpService.HttpEnabled = wasEnabled")
    lines.append('return "synced " .. count .. " scripts"')
    print("\n".join(lines))


if __name__ == "__main__":
    main()
