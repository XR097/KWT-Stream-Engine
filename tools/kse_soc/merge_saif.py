#!/usr/bin/env python3
"""Sum several SAIF files of the same design scope into one (exact).

Each input is one scoring window converted by fsdb2saif with the same scope,
so the files have identical structure (same instances/signals in the same
order).  T0/T1/TX/TZ/TC/IG are summed per signal and DURATION is the sum of the
window durations. fsdb2saif omits TZ when it is zero; that optional field may
differ between windows. Any other structural difference aborts.
usage: merge_saif.py out.saif in1.saif in2.saif ...
"""
import re
from itertools import zip_longest
import sys

NUM = re.compile(r"\((T0|T1|TX|TZ|TC|IG|DURATION) (\d+)\)")
OPTIONAL_Z = re.compile(r" ?\(TZ \d+\)")


def main():
    out, ins = sys.argv[1], sys.argv[2:]
    fs = [open(p) for p in ins]
    n_sig = 0
    with open(out, "w") as fo:
        for lines in zip_longest(*fs):
            if any(line is None for line in lines):
                raise SystemExit("files have different lengths")
            if "(DATE " in lines[0]:
                fo.write(lines[0]); continue
            keys = [NUM.sub(lambda m: "(%s #)" % m.group(1),
                            OPTIONAL_Z.sub("", l)) for l in lines]
            if any(k != keys[0] for k in keys):
                raise SystemExit("structure differs:\n" + "\n".join(lines))
            vals = [dict(NUM.findall(l)) for l in lines]
            if any(vals):
                fields = set().union(*(v.keys() for v in vals))
                tot = {k: sum(int(v.get(k, 0)) for v in vals) for k in fields}
                merged = NUM.sub(lambda m: "(%s %d)" % (m.group(1), tot[m.group(1)]), lines[0])
                if "TZ" in fields and "TZ" not in vals[0]:
                    # This converter emits TZ on the T0/T1/TX line.
                    if "TX" not in vals[0]:
                        raise SystemExit("unexpected TZ location")
                    merged = merged.rstrip("\n") + " (TZ %d)\n" % tot["TZ"]
                fo.write(merged)
                if "(TC " in lines[0]:
                    n_sig += 1
            else:
                fo.write(lines[0])
        for f in fs:
            if f.readline():
                raise SystemExit("files have different lengths")
    print(f"SAIF_MERGE_OK inputs={len(ins)} signals={n_sig} -> {out}")


if __name__ == "__main__":
    main()
