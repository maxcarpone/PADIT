# -*- coding: utf-8 -*-
from __future__ import print_function

import time
import idna
from idna import core
from idna.codec import IncrementalEncoder, IncrementalDecoder

import os
import sys

runtime = os.path.realpath(sys.prefix)
module = os.path.realpath(idna.__file__)
assert module.startswith(runtime + os.sep), module

def reject_quickly(name, func):
    start = time.time()
    try:
        func()
    except idna.IDNAError:
        elapsed = time.time() - start
        if elapsed > 2.0:
            raise AssertionError("%s rejection too slow: %.3fs" %
                                 (name, elapsed))
        print("[PASS] %s rejected (%.4fs)" % (name, elapsed))
    else:
        raise AssertionError("%s accepted oversized input" % name)

# CONTEXTO-heavy input, corresponding to the upstream regression case.
payload = u"\u30fb" * 8000 + u"\u6f22"

reject_quickly("encode", lambda: idna.encode(payload))
reject_quickly("decode", lambda: idna.decode(payload))
reject_quickly("check_label", lambda: core.check_label(payload))
reject_quickly("alabel", lambda: core.alabel(payload))
reject_quickly("ulabel", lambda: core.ulabel(payload))
reject_quickly("uts46_remap", lambda: core.uts46_remap(payload))

# Direct internal helpers.
reject_quickly("check_bidi", lambda: core.check_bidi(payload))
reject_quickly("check_nfc", lambda: core.check_nfc(payload))
reject_quickly("valid_contextj",
               lambda: core.valid_contextj(payload, 0))
reject_quickly("valid_contexto",
               lambda: core.valid_contexto(payload, 0))

# Incremental codecs, including oversized inputs delivered in pieces.
reject_quickly(
    "incremental encoder",
    lambda: IncrementalEncoder().encode(payload, True)
)
reject_quickly(
    "incremental decoder",
    lambda: IncrementalDecoder().decode(payload, True)
)

print("[PASS] W15-S / IDNA security regression suite")
