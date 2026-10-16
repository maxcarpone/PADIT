# -*- coding: utf-8 -*-
from __future__ import print_function

import idna
from idna.codec import IncrementalEncoder, IncrementalDecoder

assert idna.__file__.startswith(
    "/tmp/padit-idna-W15-validation/idna/"
)

def reject(name, function):
    try:
        function()
    except idna.IDNAError:
        print("[PASS] Rejected:", name)
    else:
        raise AssertionError("Accepted: " + name)

def domain_of_length(n):
    parts = []
    while n > 63:
        parts.append("a" * 63)
        n -= 64
    parts.append("a" * n)
    return ".".join(parts)

# Three Unicode dot separators defined by IDNA.
separators = (u"\u3002", u"\uff0e", u"\uff61")

for separator in separators:
    domain = u"example" + separator + u"com"

    enc = IncrementalEncoder()
    result = enc.encode(domain[:8], False)
    result += enc.encode(domain[8:], True)
    assert result == "example.com"

    dec = IncrementalDecoder()
    result = dec.decode(domain[:8], False)
    result += dec.decode(domain[8:], True)
    assert result == u"example.com"

    print("[PASS] Unicode separator:", repr(separator))

# Maximum valid ASCII domain with a Unicode trailing separator.
valid = domain_of_length(253)

for separator in separators:
    enc = IncrementalEncoder()
    result = enc.encode(valid[:192], False)
    result += enc.encode(valid[192:] + separator, True)
    assert result == valid + "."
    print("[PASS] Unicode trailing separator:", repr(separator))

# Empty final call after a complete domain.
for cls, method, value in (
    (IncrementalEncoder, "encode", u"example.com"),
    (IncrementalDecoder, "decode", "example.com"),
):
    obj = cls()
    first = getattr(obj, method)(value, False)
    second = getattr(obj, method)(value[:0], True)
    assert first + second == value
    print("[PASS] Empty final:", cls.__name__)

# A complete 254-character domain without a trailing separator is invalid.
invalid = valid + "a"

reject(
    "encoder final boundary",
    lambda: IncrementalEncoder().encode(invalid, True)
)

reject(
    "decoder final boundary",
    lambda: IncrementalDecoder().decode(invalid, True)
)

print("[PASS] W15-AB / Unicode codec regression suite")
