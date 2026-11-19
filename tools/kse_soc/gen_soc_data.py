#!/usr/bin/env python3
"""Build the per-task loader images and expected outputs for the KSE SoC bench.

One-time format conversion (not timed, per the official Q&A): for each task the
loader image is the 1584-word input (sample_XX_input_int.bin, int8 99x64,
little-endian words) followed by the 79008-word parameter stream v3
(params.bin from tools/kse/pack_params.py).  The expected output is
sample_XX_output.bin, copied verbatim into a word hex file.  Nothing here
computes an expected value.

The 24 frozen golden samples are two per class in class order
(cache/selections.json "golden24": validation labels 0,0,1,1,...,11,11); the
regression takes one sample per class: samples 0,2,...,22.  The class of each
chosen sample is read from the validation label file if numpy is available and
otherwise taken from that documented ordering.

Outputs in --out: task_XX_img.hex, task_XX_out.hex, tasks.txt, manifest.json
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

IN_WORDS = 1584
LAYER_WORDS = 6584
PARAM_WORDS = 12 * LAYER_WORDS


def words(b):
    assert len(b) % 4 == 0
    return list(struct.unpack("<%dI" % (len(b) // 4), b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", required=True)
    ap.add_argument("--params", required=True, help="params.bin (kse-param-stream-v3)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--samples", default=",".join(str(2 * k) for k in range(12)))
    a = ap.parse_args()
    g = Path(a.golden)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    pbytes = Path(a.params).read_bytes()
    params = words(pbytes)
    if len(params) != PARAM_WORDS:
        raise SystemExit(f"params.bin has {len(params)} words, expected {PARAM_WORDS}")
    samples = [int(x) for x in a.samples.split(",")]

    labels = None
    try:
        import numpy as np  # noqa: F401
        sel = json.loads((g.parents[1] / "cache/selections.json").read_text())["golden24"]
        lab = np.load(g.parents[1] / "cache/validation_full.npz")["labels"]
        labels = [int(lab[i]) for i in sel]
    except Exception:  # documented ordering: two samples per class
        labels = [k // 2 for k in range(24)]

    man = {"format": "kse-soc-task-v1", "in_words": IN_WORDS, "param_words": PARAM_WORDS,
           "image_words": IN_WORDS + PARAM_WORDS,
           "params_sha256": hashlib.sha256(pbytes).hexdigest(), "tasks": []}
    lines = []
    for t, s in enumerate(samples):
        ib = (g / f"sample_{s:02d}_input_int.bin").read_bytes()
        ob = (g / f"sample_{s:02d}_output.bin").read_bytes()
        if len(ib) != 4 * IN_WORDS or len(ob) != 4 * IN_WORDS:
            raise SystemExit(f"sample {s}: unexpected input/output size")
        img = words(ib) + params
        (out / f"task_{t:02d}_img.hex").write_text("".join("%08x\n" % w for w in img))
        (out / f"task_{t:02d}_out.hex").write_text("".join("%08x\n" % w for w in words(ob)))
        man["tasks"].append({"task": t, "sample": s, "label": labels[s],
                             "input_sha256": hashlib.sha256(ib).hexdigest(),
                             "output_sha256": hashlib.sha256(ob).hexdigest()})
        lines.append(f"{t} {s} {labels[s]}\n")
    if len(samples) == 12 and sorted(labels[s] for s in samples) != list(range(12)):
        raise SystemExit("the chosen samples do not cover the 12 classes exactly once")
    (out / "tasks.txt").write_text("".join(lines))
    (out / "manifest.json").write_text(json.dumps(man, indent=1) + "\n")
    print(f"SOC_DATA_OK tasks={len(samples)} image_words={IN_WORDS + PARAM_WORDS} -> {out}")


if __name__ == "__main__":
    main()
