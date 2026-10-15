# -*- coding: utf-8 -*-
"""PADIT Unix agent: python-ldap 3.3.1 security regressions.

Run with Python 2.7:
    python test-agent-unix-python-ldap.py /path/to/source/Lib/ldap

Tests:
    GHSA-r8wq-qrxc-hmcm / CVE-2021-46823
    CVE-2025-61911
    CVE-2025-61912
"""

from __future__ import print_function

import ast
import imp
import os
import signal
import sys
import time


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("PASS:", message)


def load_function(path, name):
    with open(path, "rb") as handle:
        tree = ast.parse(handle.read(), filename=path)

    functions = [
        node for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == name
    ]
    check(len(functions) == 1, "function found: " + name)

    namespace = {}
    code = compile(ast.Module(body=functions), path, "exec")
    exec code in namespace
    return namespace[name]


def timeout_handler(signum, frame):
    raise RuntimeError("ReDoS test timeout")


def main():
    if sys.version_info[0] != 2:
        raise RuntimeError("Python 2.7 required")

    if len(sys.argv) != 2:
        raise RuntimeError("Expected source Lib/ldap path")

    root = os.path.abspath(sys.argv[1])

    filter_path = os.path.join(root, "filter.py")
    dn_path = os.path.join(root, "dn.py")
    tokenizer_path = os.path.join(root, "schema", "tokenizer.py")

    for path in (filter_path, dn_path, tokenizer_path):
        check(os.path.isfile(path), "source exists: " + path)

    escape_filter = load_function(filter_path, "escape_filter_chars")
    escape_dn = load_function(dn_path, "escape_dn_chars")

    check(
        escape_filter("a*b(c)") == r"a\2ab\28c\29",
        "normal filter escaping"
    )
    check(
        escape_filter("a\x00b") == r"a\00b",
        "filter NUL escaping"
    )
    check(
        escape_filter("ABC", 2) == r"\41\42\43",
        "filter escape mode 2"
    )

    for value in (None, 42, ["a"], u"texte"):
        try:
            escape_filter(value)
        except TypeError:
            pass
        else:
            raise AssertionError(
                "CVE-2025-61911: invalid type accepted: %r" % (value,)
            )

    print("PASS: CVE-2025-61911 type validation")

    escaped = escape_dn("a\x00b")
    check(
        escaped == r"a\00b" and "\x00" not in escaped,
        "CVE-2025-61912 NUL escaping"
    )
    check(escape_dn("a,b") == r"a\,b", "normal DN escaping")
    check(escape_dn("#abc") == r"\#abc", "initial DN hash")
    check(escape_dn(" abc ") == r"\ abc\ ", "DN edge spaces")

    tokenizer = imp.load_source(
        "padit_ldap_security_tokenizer", tokenizer_path
    )

    check(
        tokenizer.split_tokens("( NAME 'example' )")
        == ["(", "NAME", "example", ")"],
        "normal schema tokenization"
    )

    check(
        tokenizer.split_tokens("( NAME 'a\\\\b' )")
        == ["(", "NAME", "a\\b", ")"],
        "schema escaped backslash"
    )

    signal.signal(signal.SIGALRM, timeout_handler)

    for length in (32, 64, 128, 256):
        payload = "'" + ("\\" * length)
        started = time.time()

        signal.alarm(3)
        try:
            result = tokenizer.TOKENS_FINDALL(payload)
        finally:
            signal.alarm(0)

        duration = time.time() - started
        check(
            isinstance(result, list),
            "ReDoS length=%d duration=%.6fs" % (length, duration)
        )

    print("[PASS] PADIT python-ldap security regressions")


if __name__ == "__main__":
    main()
