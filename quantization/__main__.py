import argparse
import os
from pathlib import Path
from .data import default_data_root
from .pipeline import run, prepare, baseline, calibrate, sweep, evaluate, export


def _data_root(value, repo_root):
    if value:
        return value
    return os.environ.get("KWT_DATA_ROOT", str(default_data_root(repo_root)))

def main():
    p = argparse.ArgumentParser(prog="python -m quantization")
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("run", "prepare", "baseline", "calibrate", "sweep", "evaluate", "export"):
        q = sub.add_parser(name); q.add_argument("--data-root", default=None); q.add_argument("--repo-root", default=".")
        q.add_argument("--resume", action="store_true")
    q = sub.add_parser("experiment")
    q.add_argument("--data-root", default=None)
    q.add_argument("--repo-root", default=".")
    q.add_argument("--resume", action="store_true")
    q.add_argument("--workers", type=int, default=4, choices=range(1, 9))
    q.add_argument("--stage", choices=("all", "prepare", "residual", "weights", "nonlinear", "joint", "final", "report"), default="all")
    a = p.parse_args()
    a.data_root = _data_root(a.data_root, a.repo_root)
    if a.command == "experiment":
        from .experiments import run_experiments
        run_experiments(a)
        return
    if a.command == "run": run(a); return
    fn = {"prepare": prepare, "baseline": baseline, "calibrate": calibrate, "sweep": sweep, "evaluate": evaluate, "export": export}[a.command]
    state = {}; fn(a, state)

if __name__ == "__main__": main()
