# -*- coding: utf-8 -*-
from __future__ import print_function

import idna
from idna.codec import IncrementalEncoder, IncrementalDecoder


def reject(label, func):
    try:
        func()
    except idna.IDNAError:
        print("[PASS] Rejected:", label)
    else:
        raise AssertionError("Accepted: " + label)


def domain_of_length(n):
    parts = []
    while n > 63:
        parts.append("a" * 63)
        n -= 64
    parts.append("a" * n)
    return ".".join(parts)


valid = domain_of_length(253)
assert len(valid) == 253

# Valid domain delivered across several calls.
enc = IncrementalEncoder()
result = ""
for part in (valid[:64], valid[64:128], valid[128:192]):
    result += enc.encode(part, False)
result += enc.encode(valid[192:], True)
assert result == valid
print("[PASS] Fragmented 253-character encoding")

dec = IncrementalDecoder()
result = u""
for part in (valid[:64], valid[64:128], valid[128:192]):
    result += dec.decode(part, False)
result += dec.decode(valid[192:], True)
assert result == valid
print("[PASS] Fragmented 253-character decoding")

# Final empty call following a fully emitted trailing dot.
enc = IncrementalEncoder()
result = enc.encode(valid + ".", False)
result += enc.encode(u"", True)
assert result == valid + "."
print("[PASS] Trailing dot followed by empty final call")

# Exceed the maximum through multiple individually valid chunks.
enc = IncrementalEncoder()
enc.encode(valid[:192], False)
reject(
    "fragmented encoder overflow",
    lambda: enc.encode(valid[192:] + "a", True)
)

dec = IncrementalDecoder()
dec.decode(valid[:192], False)
reject(
    "fragmented decoder overflow",
    lambda: dec.decode(valid[192:] + "a", True)
)

# A fresh codec must remain functional after another codec failed.
assert IncrementalEncoder().encode(u"example.com", True) == "example.com"
assert IncrementalDecoder().decode("example.com", True) == u"example.com"
print("[PASS] Fresh codec unaffected by previous errors")

print("[PASS] W15-V / Incremental boundary regression suite")
