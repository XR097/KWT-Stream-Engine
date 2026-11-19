#!/usr/bin/env python3
"""Summarize tb_kse_soc logs: per-task window cycles, breakdown and throughput.

usage: sum_soc_logs.py <expected tasks> log...
Prints REGRESSION PASSED only if exactly <expected tasks> distinct tasks
reported PASS (compared_bytes=6336, mismatches=0, errors=0), every log has
TEST PASSED, and no log has a failure marker.
"""
import re
import sys

F_HZ = 150e6
BAD = re.compile(r"TEST FAILED|TIMEOUT|^Error|Error-\[|^Fatal|Fatal:|MISMATCH|^ERROR", re.M)


def kv(line):
    return {k: v for k, v in re.findall(r"(\w+)=(-?[\w.]+)", line)}


def main():
    want = int(sys.argv[1])
    tasks, brk, ok = {}, {}, True
    for p in sys.argv[2:]:
        txt = open(p, errors="replace").read()
        if BAD.search(txt) or "TEST PASSED" not in txt:
            print(f"LOG_FAIL {p}")
            ok = False
        for line in txt.splitlines():
            if line.startswith("TASK "):
                t = int(line.split()[1])
                d = kv(line)
                d["pass"] = line.rstrip().endswith("PASS") and d["compared_bytes"] == "6336" \
                    and d["mismatches"] == "0" and d["errors"] == "0"
                if t in tasks:
                    print(f"DUPLICATE task {t}"); ok = False
                tasks[t] = d
            elif line.startswith("BREAKDOWN "):
                d = kv(line)
                brk.setdefault(int(d["task"]), {}).update(d)
    print("| 任务 | 样本 | 类别 | 结果 | 窗口周期 | E203 启动 | 引擎 | 写回排空 | E203 收尾 | 加载器跨度 | 加载器等待 |")
    print("|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|")
    tot = 0
    for t in sorted(tasks):
        d, b = tasks[t], brk.get(t, {})
        tot += int(d["window_cycles"])
        print(f"| {t} | {d['sample']} | {d['label']} | {'PASS' if d['pass'] else 'FAIL'} | {d['window_cycles']} | "
              f"{b.get('first_write_to_cmd0')} | {b.get('engine_cmd0_to_done11')} | {b.get('drain_done11_to_evt')} | "
              f"{b.get('evt11_to_flag')} | {b.get('loader_span')} | {b.get('loader_stall')} |")
    npass = sum(1 for d in tasks.values() if d["pass"])
    labels = sorted(int(d["label"]) for d in tasks.values())
    if npass:
        print(f"TOTAL tasks={len(tasks)} pass={npass} total_window_cycles={tot} mean={tot / len(tasks):.1f} "
              f"throughput_150MHz={F_HZ * len(tasks) / tot:.2f} tasks/s")
    if ok and npass == want and len(tasks) == want and (want != 12 or labels == list(range(12))):
        print("REGRESSION PASSED")
    else:
        print("REGRESSION FAILED")


if __name__ == "__main__":
    main()
