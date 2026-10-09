#!/usr/bin/env python3
"""Scrub credentials from the research artifacts in this repo, in place.

The captures under spec/raw/ were taken through a logging proxy and contain real session
cookies, CSRF tokens, and in one case a plaintext login body. Their value is the
request/response *shape*, not the credentials, so values are replaced with stable
placeholders rather than deleting the evidence.

Quoting matters here. The captures nest an HTTP request body *inside* a JSON string, so the
bytes on disk look like  \\"password\\":\\"hunter2\\"  — a pattern that only handles plain
quotes silently matches nothing and reports "clean". Every quote in every rule below is
`(?:\\?")`, i.e. a quote that may or may not be escaped.

Idempotent, and documentation placeholders ("string", "optional", "...") are left alone so
the spec stays readable.

    python3 tools/redact_capture.py           # scrub
    python3 tools/redact_capture.py --check   # report only; exit 1 if anything is found
"""
from __future__ import annotations

import json

import argparse
import pathlib
import re
import sys
from typing import Callable, Union

Q = r'(?:\\?")'                       # a double quote, escaped or not
UUID = r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# Values that are obviously not secrets, so re-running never mangles the docs.
# `…`, `...`, `***` and `<anything>` are the universal "this is a shape, not a value"
# conventions. Without them the scrubber eats the request bodies in the spec, and a
# reference that cannot show a body is not a reference.
NOT_A_SECRET = r'(?!\s*(?:\.\.\.|\u2026|\*\*?\*+|<|string\b|optional\b|example\b|<REDACTED))'

Repl = Union[str, Callable[[re.Match], str]]

# --- always on (a JWT is never legitimate text in this repo) -------------------------------
JWT_RULES: list[tuple[re.Pattern, Repl]] = [
    (re.compile(r"(TOKEN=)eyJ[A-Za-z0-9_.\-]+"), r"\1<REDACTED-JWT>"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
     "<REDACTED-JWT>"),
]

# --- data + prose only (these shapes occur legitimately in source code) -------------------
LOOSE_RULES: list[tuple[re.Pattern, Repl]] = [
    # {"password":"..."} in plain and escaped form. The closing quote of the KEY is escaped
    # too — `\"password\":` — so omitting it after the key name matches nothing at all.
    (re.compile(r"(?i)(password" + Q + r"\s*:\s*" + Q + ")" + NOT_A_SECRET +
                r"(?:[^\"\\]|\\.)*?(?=" + Q + ")"),
     lambda m: m.group(1) + "<REDACTED>"),
    # password=... in query strings and curl examples
    (re.compile(r"(?i)(password\s*=\s*)[^\s&,\"']+"), r"\1<REDACTED>"),
    # "x-csrf-token":"<uuid>" / "csrfToken":"<uuid>", plain and escaped
    (re.compile(r"(?i)((?:x-csrf-token|x-updated-csrf-token|csrfToken)" + Q +
                r"\s*:\s*" + Q + ")" + UUID + Q),
     lambda m: m.group(1) + "<REDACTED-CSRF>\""),
    # bare header lines: x-csrf-token: <uuid>
    (re.compile(r"(?i)^(\s*(?:x-csrf-token|x-updated-csrf-token)\s*[:=]\s*)" + UUID, re.M),
     r"\1<REDACTED-CSRF>"),
    # csrfToken = <uuid> anywhere else
    (re.compile(r"(?i)(csrf[_-]?token[\"'\s=:]+)" + UUID), r"\1<REDACTED-CSRF>"),
    # UniFi OS API keys are 32 base62 chars, near the words "api key"
    (re.compile(r"\b[A-Za-z0-9]{32}\b(?=.{0,40}(?i:api[_ -]?key))"), "<REDACTED-API-KEY>"),
    # passwordRevision is the server-side token epoch. Only the field name matters to the spec.
    (re.compile(r'(?i)("?password_?revision"?\s*[:=]\s*"?)\d+'), r"\1<REDACTED>"),
]

# --- literal PII -------------------------------------------------------------------------
# The captures are kept because their *shape* is the research. An operator's name, mailbox
# and SSO handle are not part of any shape. A fixed table rather than a pattern: a generic
# "looks like an email" rule would eat the example addresses that keep the spec readable.
# Anyone reusing this repo for their own console edits this list, not the rules.
# Loaded from tools/pii.json (untracked) so this file can be published without carrying
# anyone's name, mailbox or SSO handle. Format:
#   [["whoever you are", "Example User"], ["whoever@example.com", "user@example.com"]]
# Run this tool after editing it; --check uses the same table.
PII_FILE = pathlib.Path(__file__).with_name("pii.json")
PII: list[tuple[str, str]] = []
if PII_FILE.exists():
    PII = [(a, b) for a, b in json.loads(PII_FILE.read_text())]

TARGETS = ["spec", "docs", "tools", "apps", "README.md"]

# `self.password = password` is real code, so the loose rules are confined to captured data
# and prose.
DATA_ONLY = {".json", ".jsonl", ".md", ".txt", ".yaml", ".yml"}
# This file necessarily contains the patterns it hunts for.
SKIP = {"tools/redact_capture.py", "tools/pii.json"}

SCAN_SUFFIXES = {".md", ".json", ".jsonl", ".py", ".swift", ".rs", ".toml",
                 ".txt", ".sh", ".yaml", ".yml"}


def iter_files(root: pathlib.Path):
    for name in TARGETS:
        p = root / name
        if p.is_file():
            yield p
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and f.suffix in SCAN_SUFFIXES:
                    yield f


def scrub(text: str, suffix: str) -> tuple[str, int]:
    rules = JWT_RULES + (LOOSE_RULES if suffix in DATA_ONLY else [])
    out = text
    hits = 0
    for pat, repl in rules:
        out, n = pat.subn(repl, out)
        hits += n
    for old, new in PII:
        if old in out:
            hits += out.count(old)
            out = out.replace(old, new)
    return out, hits


# Every rule must actually fire on at least one fixture. A pattern that quietly matches
# nothing makes --check report "clean" while the secret is still on disk — which is exactly
# how the escaped-quote bug survived a full scrub pass.
FIXTURES: list[tuple[str, str, list[str]]] = [
    # (suffix, input, substrings that MUST appear in the output)
    (".jsonl", r'{"username":"***REMOVED***","password":"hunter2"}',
     ['"password":"<REDACTED>"']),
    (".jsonl", r'"preview": "{\"username\":\"b\",\"password\":\"hunter2\"}"',
     ['<REDACTED>']),
    # Fixture values are deliberately synthetic so no real credential lives in this file.
    (".jsonl", "Set-Cookie: TOKEN=eyJFAKEHEADER.eyJFAKEPAYLOAD.FAKESIGNATURE",
     ['TOKEN=<REDACTED-JWT>']),
    (".jsonl", '{"password_revision":1700000000,"passwordRevision":1700000000}',
     ['<REDACTED>']),
    # The PII table itself is exercised in selftest() with a synthetic table; its real values
    # must never be written into this file.
    (".jsonl", r'{"x-csrf-token":"00000000-0000-4000-8000-000000000000"}',
     ['<REDACTED-CSRF>']),
    (".jsonl", r'"req_headers": {\"x-csrf-token\":\"00000000-0000-4000-8000-000000000000\"}',
     ['<REDACTED-CSRF>']),
    (".md", "x-csrf-token: 00000000-0000-4000-8000-000000000000", ["<REDACTED-CSRF>"]),
    (".md", "use api_key = AAAA5555bbbb6666CCCC7777dddd8888 for the api key",
     ["<REDACTED-API-KEY>"]),
    (".md", "curl -d 'password=hunter2&x=1'", ["password=<REDACTED>"]),
    # Placeholders must survive untouched. A scrubber that eats the request bodies in the
    # spec destroys the thing the spec exists to communicate, so "does not fire on a
    # placeholder" is tested as hard as "does fire on a secret".
    ('.md', '{"username": "string", "password": "string"}', ['"password": "string"']),
    ('.md', '{"password": "\u2026"}', ['"password": "\u2026"']),
    ('.md', '{"password":"***"}', ['"password":"***"']),
    ('.md', '{"password":"<your console password>"}', ['"password":"<your console password>"']),
    ('.md', '{"password": "optional"}', ['"password": "optional"']),
    (".md", '"password": "optional"', ['"password": "optional"']),
]


def selftest() -> int:
    # Prove the PII mechanism without quoting the table's real values.
    saved = list(PII)
    try:
        PII[:] = [("Ada Quux", "Example User"), ("ada@quux.test", "user@example.com")]
        probe = '{"fullName":"Ada Quux","email":"ada@quux.test"}'
        out, n = scrub(probe, ".jsonl")
        if n != 2 or "Ada Quux" in out or "ada@quux.test" in out:
            print(f"FAIL pii mechanism: n={n} out={out}")
    finally:
        PII[:] = saved

    failed = 0
    for i, (suffix, src, expected) in enumerate(FIXTURES):
        out, _ = scrub(src, suffix)
        missing = [e for e in expected if e not in out]
        leaked = ("hunter2" in out or "00000000-0000-4000-8000" in out
                  or "AAAA5555bbbb6666" in out or "eyJFAKEHEADER" in out)
        ok = not missing and not leaked
        print(f"  {'ok  ' if ok else 'FAIL'} fixture {i}: {src[:52]!r}")
        if missing:
            print(f"        expected {missing} in {out!r}")
        if leaked:
            print(f"        SECRET SURVIVED: {out!r}")
        failed += 0 if ok else 1
    print("selftest passed" if not failed else f"{failed} fixture(s) failed")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report only, do not write")
    ap.add_argument("--selftest", action="store_true",
                    help="verify every rule actually fires; exit 1 if not")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    root = pathlib.Path(__file__).resolve().parent.parent
    changed = 0
    for f in iter_files(root):
        rel = str(f.relative_to(root))
        if rel in SKIP:
            continue
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        out, hits = scrub(text, f.suffix)
        if out != text:
            print(f"  {'would scrub' if args.check else 'scrubbed'}: {rel}  ({hits} matches)")
            if not args.check:
                f.write_text(out, encoding="utf-8")
            changed += 1

    if args.check:
        print("clean" if changed == 0 else f"{changed} file(s) contain credentials")
        return 1 if changed else 0
    print("done" if changed else "nothing to scrub")
    return 0


if __name__ == "__main__":
    sys.exit(main())
