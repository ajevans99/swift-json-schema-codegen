#!/usr/bin/env python3
"""Check the vendored meta-schema resource graph without accessing the network."""

import hashlib
import json
from pathlib import Path
from urllib.parse import unquote, urldefrag, urljoin


ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "Examples/MetaSchemaExample/Sources/MetaSchemaExample/Schemas"
BASE = "https://json-schema.org/draft/2020-12/"
EXPECTED = {
    "meta.schema.json": BASE + "schema",
    **{
        f"meta/{name}.schema.json": BASE + f"meta/{name}"
        for name in (
            "core",
            "applicator",
            "unevaluated",
            "validation",
            "meta-data",
            "format-annotation",
            "content",
        )
    },
}


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def main():
    paths = {p.relative_to(SCHEMAS).as_posix() for p in SCHEMAS.rglob("*.schema.json")}
    check(paths == set(EXPECTED), "expected exactly eight official schema documents")

    checksums = {}
    for line in (SCHEMAS / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        checksums[name] = digest
    check(set(checksums) == set(EXPECTED), "checksum manifest does not match the schema documents")

    documents = {}
    for name, identifier in EXPECTED.items():
        data = (SCHEMAS / name).read_bytes()
        check(hashlib.sha256(data).hexdigest() == checksums[name], f"checksum mismatch: {name}")
        schema = json.loads(data)
        check(schema.get("$id") == identifier, f"canonical $id changed: {name}")
        check(schema.get("$schema") == BASE + "schema", f"unexpected dialect: {name}")
        check(schema.get("$dynamicAnchor") == "meta", f"missing dynamic anchor: {name}")
        documents[identifier] = schema

    reference_count = 0
    for identifier, schema in documents.items():
        for node in walk(schema):
            for keyword in ("$schema", "$ref", "$dynamicRef"):
                if not isinstance(node.get(keyword), str):
                    continue
                target_id, fragment = urldefrag(urljoin(identifier, node[keyword]))
                check(target_id in documents, f"reference not available offline: {node[keyword]}")
                target = documents[target_id]
                fragment = unquote(fragment)
                if fragment.startswith("/"):
                    for token in fragment[1:].split("/"):
                        token = token.replace("~1", "/").replace("~0", "~")
                        if isinstance(target, list):
                            target = target[int(token)]
                        else:
                            check(token in target, f"unresolved JSON Pointer: {node[keyword]}")
                            target = target[token]
                elif fragment:
                    check(
                        any(
                            candidate.get("$anchor") == fragment
                            or candidate.get("$dynamicAnchor") == fragment
                            for candidate in walk(target)
                        ),
                        f"unresolved anchor: {node[keyword]}",
                    )
                reference_count += 1

    print(f"Meta-schema fixtures passed: {len(documents)} canonical documents, {reference_count} local references.")


if __name__ == "__main__":
    main()
