from __future__ import print_function
import dns.name

def make_chain(hops):
    wire = bytearray(b"\x00")
    offsets = []

    for index in range(hops):
        offsets.append(len(wire))
        wire.extend(b"\x00\x00")

    for index, offset in enumerate(offsets):
        destination = 0 if index == 0 else offsets[index - 1]
        wire[offset] = 0xc0 | (destination >> 8)
        wire[offset + 1] = destination & 0xff

    return bytes(wire), offsets[-1]

wire, offset = make_chain(16)
dns.name.from_wire(wire, offset)
print("[PASS] 16 compression pointers accepted")

wire, offset = make_chain(17)
try:
    dns.name.from_wire(wire, offset)
except dns.name.BadPointer:
    print("[PASS] 17 compression pointers rejected")
else:
    raise AssertionError("17 compression pointers accepted")

print("[PASS] CVE-2026-114605 regression")
