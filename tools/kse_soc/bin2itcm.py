#!/usr/bin/env python3
"""Convert a flat ITCM binary (based at 0x8000_0000) into one 64-bit
little-endian word per line for the E203 ITCM sim RAM (mem_r)."""
import sys
data = open(sys.argv[1], "rb").read()
data += b"\0" * (-len(data) % 8)
if len(data) > 64 * 1024:
    raise SystemExit("image exceeds the 64 KiB ITCM")
with open(sys.argv[2], "w") as f:
    for i in range(0, len(data), 8):
        f.write("%016x\n" % int.from_bytes(data[i:i + 8], "little"))
print("ITCM words:", len(data) // 8)
