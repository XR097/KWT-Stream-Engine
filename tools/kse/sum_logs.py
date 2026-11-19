#!/usr/bin/env python3
"""Aggregate CMP/TASK lines of several tb_kse_top logs (parallel network runs).

usage: sum_logs.py <expected_samples> log...
Fails if any log has TIMEOUT/ERROR lines or no TEST PASSED, if the number of
completed tasks differs from expected_samples, or if any element mismatched.
"""
import re
import sys

expect = int(sys.argv[1])
logs = sys.argv[2:]
tot, tasks, passed, failed, problems = {}, [], 0, 0, []
for f in logs:
    p = 0
    for line in open(f):
        m = re.match(r"CMP (.+?)\s+compared=(\d+) mismatches=(\d+)", line)
        if m:
            a = tot.setdefault(m.group(1), [0, 0])
            a[0] += int(m.group(2))
            a[1] += int(m.group(3))
        m = re.match(r"TASK sample=(\d+) cycles=(\d+)", line)
        if m:
            tasks.append((int(m.group(1)), int(m.group(2))))
        if line.startswith("TIMEOUT") or line.startswith("ERROR ") or re.match(r"ERRORS=[1-9]", line):
            problems.append(f"{f}: {line.strip()}")
        if line.startswith("TEST PASSED"):
            p += 1
        failed += line.startswith("TEST FAILED")
    passed += (p == 1)
for k, (c, b) in tot.items():
    print(f"CMP {k:<24s} compared={c} mismatches={b}")
c = sum(v[0] for v in tot.values())
b = sum(v[1] for v in tot.values())
samples = sorted(set(s for s, _ in tasks))
print(f"SAMPLES {len(samples)} (expected {expect}) task_cycles={sorted(set(t for _, t in tasks))}")
for pr in problems:
    print("PROBLEM", pr)
print(f"TOTAL compared={c} mismatches={b} logs_passed={passed}/{len(logs)} logs_failed={failed}")
ok = (b == 0 and c > 0 and failed == 0 and passed == len(logs) and not problems
      and len(samples) == expect and len(tasks) == expect)
print("TEST PASSED" if ok else "TEST FAILED")
sys.exit(0 if ok else 1)
