# -*- coding: utf-8 -*-
from __future__ import print_function

import idna
from idna.codec import IncrementalEncoder, IncrementalDecoder

import os
import sys

runtime = os.path.realpath(sys.prefix)
module = os.path.realpath(idna.__file__)
assert module.startswith(runtime + os.sep), module

def rejected(func, description):
    try:
        func()
    except idna.IDNAError:
        print("[PASS] Rejected:", description)
    else:
        raise AssertionError("Accepted: " + description)

def domain_of_length(n):
    parts = []
    while n > 63:
        parts.append("a" * 63)
        n -= 64
    parts.append("a" * n)
    return ".".join(parts)

# Normal fragmented encoding and decoding.
enc = IncrementalEncoder()
encoded = enc.encode(u"example.", False)
encoded += enc.encode(u"com", True)
assert encoded == "example.com"
print("[PASS] Fragmented encoding")

dec = IncrementalDecoder()
decoded = dec.decode("example.", False)
decoded += dec.decode("com", True)
assert decoded == u"example.com"
print("[PASS] Fragmented decoding")

# Domain-length boundaries.
valid253 = domain_of_length(253)
assert len(valid253) == 253

enc = IncrementalEncoder()
encoded = enc.encode(valid253[:128], False)
encoded += enc.encode(valid253[128:], True)
assert encoded == valid253
print("[PASS] 253-character domain accepted")

dec = IncrementalDecoder()
decoded = dec.decode(valid253[:128], False)
decoded += dec.decode(valid253[128:], True)
assert decoded == valid253
print("[PASS] 253-character domain decoded")

valid254 = valid253 + "."
enc = IncrementalEncoder()
encoded = enc.encode(valid254[:128], False)
encoded += enc.encode(valid254[128:], True)
assert encoded == valid254
print("[PASS] 254-character trailing-dot domain accepted")

invalid254 = valid253 + "a"
rejected(
    lambda: IncrementalEncoder().encode(invalid254, True),
    "254-character domain without trailing dot"
)

invalid255 = valid254 + "a"
rejected(
    lambda: IncrementalDecoder().decode(invalid255, True),
    "255-character domain"
)

# State and reset functionality.
enc = IncrementalEncoder()
enc.encode(u"example.", False)
state = enc.getstate()
enc2 = IncrementalEncoder()
enc2.setstate(state)
assert enc2.encode(u"com", True) == "com"
enc2.reset()
assert enc2.encode(u"new.org", True) == "new.org"
print("[PASS] Encoder getstate/setstate/reset")

dec = IncrementalDecoder()
dec.decode("example.", False)
state = dec.getstate()
dec2 = IncrementalDecoder()
dec2.setstate(state)
assert dec2.decode("com", True) == u"com"
dec2.reset()
assert dec2.decode("new.org", True) == u"new.org"
print("[PASS] Decoder getstate/setstate/reset")

print("[PASS] W15-R / Incremental codec regression suite")
