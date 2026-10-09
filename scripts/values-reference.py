#!/usr/bin/env python3
"""values-reference.py <schema.json> <README.md> [--check]: write the values table between the
<!-- values-reference:start --> and <!-- values-reference:end --> markers of README.md from the schema.

Every property with a "description" is a row: its dotted key, its "x-default" and its description. An open
map (additionalProperties) is labelled <name>, or the property's "x-doc-key". "x-doc-rows" adds rows the
schema's shape can't express, and "x-doc-leaf" stops the walk below a property documented elsewhere. Every
top-level property must produce a row. With --check, fail instead of writing when the table is stale."""
import json, sys

START, END = "<!-- values-reference:start -->", "<!-- values-reference:end -->"
schema = json.load(open(sys.argv[1]))
readme_path, check = sys.argv[2], "--check" in sys.argv[3:]


def resolve(node):
    while "$ref" in node:
        node = schema["definitions"][node["$ref"].split("/")[-1]]
    return node


def cell(text):
    return text.replace("|", "\\|")


rows = []


def map_key(prop, node):
    return prop.get("x-doc-key", node.get("x-doc-key", "<name>"))


def is_open_map(node):
    return isinstance(node.get("additionalProperties"), dict) and not node.get("properties")


def walk(prop, label):
    node = resolve(prop)
    if "description" in prop or "description" in node:
        shown = f"{label}.{map_key(prop, node)}" if is_open_map(node) else label
        rows.append((shown, prop.get("x-default", node.get("x-default", "")), prop.get("description", node.get("description"))))
    for extra in prop.get("x-doc-rows", []):
        rows.append((extra["key"], extra.get("default", ""), extra["description"]))
    if prop.get("x-doc-leaf") or node.get("x-doc-leaf"):
        return
    for name, child in node.get("properties", {}).items():
        walk(child, f"{label}.{name}")
    more = node.get("additionalProperties")
    if isinstance(more, dict):
        walk_map(more, f"{label}.{map_key(prop, node)}")


def walk_map(entry, label):
    entry = resolve(entry)
    for name, child in entry.get("properties", {}).items():
        walk(child, f"{label}.{name}")


for name, prop in schema["properties"].items():
    before = len(rows)
    walk(prop, name)
    if len(rows) == before:
        sys.exit(f"values-reference: top-level key {name} has no description anywhere below it")

table = ["| Key | Default | What it does |", "| --- | --- | --- |"]
table += [f"| `{key}` | {cell(default)} | {cell(desc)} |" for key, default, desc in rows]
readme = open(readme_path).read()
head, rest = readme.split(START, 1)
_, tail = rest.split(END, 1)
new = head + START + "\n" + "\n".join(table) + "\n" + END + tail
if check:
    if new != readme:
        sys.exit(f"values-reference: {readme_path} is stale; run make generate")
else:
    open(readme_path, "w").write(new)
