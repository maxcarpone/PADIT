# -*- coding: utf-8 -*-
from __future__ import print_function

import sys
import idna

import os

runtime = os.path.realpath(sys.prefix)
module = os.path.realpath(idna.__file__)

if not module.startswith(runtime + os.sep):
    raise AssertionError("idna outside runtime: %s" % module)

print("=== W15-J / IDNA 2.10 BASELINE ===")
print("Version:", idna.__version__)
print("Module:", idna.__file__)

cases = [
    u"example.com",
    u"www.example.org",
    u"bücher.de",
    u"café.fr",
    u"例子.测试",
    u"a" * 63 + u".com",
    u"a" * 63 + u"." + u"b" * 63 + u".com",
]

for domain in cases:
    encoded = idna.encode(domain)
    decoded = idna.decode(encoded)

    if idna.encode(decoded) != encoded:
        raise AssertionError("Round-trip failed: %r" % domain)

    print("[PASS] Round-trip:", repr(domain[:35]))

# Normal DNS label boundary.
assert len(idna.encode(u"a" * 63)) == 63

try:
    idna.encode(u"a" * 64)
except idna.IDNAError:
    print("[PASS] Oversized ASCII label rejected")
else:
    raise AssertionError("64-character ASCII label accepted")

# Normal Unicode label conversion.
assert idna.decode(idna.encode(u"bücher")) == u"bücher"
print("[PASS] Unicode label compatibility")

print("[PASS] W15-J / Baseline complete")
