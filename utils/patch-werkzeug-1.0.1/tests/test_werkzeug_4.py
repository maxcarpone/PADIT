import ntpath

import werkzeug.security as security
from werkzeug.security import safe_join


assert safe_join("a", "b/c") == "a/b/c"
assert safe_join("a", "../b/c") is None

# CVE-2024-49766
original_isabs = security.os.path.isabs
security.os.path.isabs = ntpath.isabs

try:
    assert safe_join("a", "//b/c") is None
finally:
    security.os.path.isabs = original_isabs

# CVE-2025-66221, CVE-2026-21860,
# CVE-2026-27199, CVE-2026-102598
original_name = security.os.name
security.os.name = "nt"

try:
    blocked = [
        "CON",
        "CON.txt",
        "CON.txt.html",
        "CON  ",
        "CON . txt",
        "CONIN$",
        "CONOUT$",
        "COM1",
        "LPT9",
        u"COM\u00b9",
        u"LPT\u00b3",
        "b/CON",
        "CON:",
        "CON::$DATA",
        "b/CON:",
    ]

    for value in blocked:
        result = safe_join("a", value)

        if result is not None:
            raise RuntimeError(
                "Werkzeug safe_join regression: unsafe path accepted: %r => %r"
                % (value, result)
            )
finally:
    security.os.name = original_name

print("WERKZEUG SAFE_JOIN CONSOLIDATED REGRESSION TEST: PASS")