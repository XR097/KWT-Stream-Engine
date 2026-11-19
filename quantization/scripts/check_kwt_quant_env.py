"""Cross-platform strict environment audit; native TF failures are isolated."""
import argparse
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def audit(repo, root):
    modules = {}
    errors = []
    versions = {"tensorflow": "2.4.0", "tensorflow_addons": "0.12.1", "numpy": "1.19.5"}
    for name in ("numpy", "scipy", "matplotlib", "pytest", "tensorflow", "tensorflow_addons"):
        result = subprocess.run([sys.executable, "-B", "-c", "import %s as m; print(m.__version__)" % name],
                                capture_output=True, text=True)
        modules[name] = {"exit_code": result.returncode, "version": result.stdout.strip(),
                         "diagnostic": result.stderr.strip()}
        if result.returncode != 0:
            errors.append(name + " import failed")
        elif name in versions and result.stdout.strip() != versions[name]:
            errors.append(name + " version differs from " + versions[name])
    checkpoint = repo / "third-party/kwt/models_data_v2_12_labels/kwt1"
    complete = all((checkpoint / name).is_file() for name in
                   ("best_weights.index", "best_weights.data-00000-of-00001"))
    if not complete:
        errors.append("checkpoint incomplete")
    if sys.version_info[:2] != (3, 8):
        errors.append("Python must be 3.8.x")
    wav_count = sum(1 for _ in (root / "data2").rglob("*.wav"))
    if not wav_count:
        errors.append("dataset not extracted")
    # A fresh checkout may not have created the data root yet.
    usage_root = root
    while not usage_root.exists() and usage_root != usage_root.parent:
        usage_root = usage_root.parent
    # Derived from this run's checks; this audit does not execute the test set.
    tf = modules["tensorflow"]
    if tf["exit_code"] != 0:
        full_test = "blocked; tensorflow import failed (exit %d): %s" % (
            tf["exit_code"], (tf["diagnostic"].splitlines() or ["no diagnostic"])[-1])
    elif errors:
        full_test = "blocked; " + "; ".join(errors)
    else:
        full_test = "ready; prerequisites passed, accuracy is not measured by this audit"
    return {"status": "passed" if not errors else "blocked", "python": platform.python_version(),
            "architecture": platform.machine(), "executable": sys.executable, "modules": modules,
            "checkpoint_files_present": complete, "wav_count": wav_count,
            "free_gib": shutil.disk_usage(usage_root).free / 1024 ** 3, "errors": errors,
            "full_4890_testing": full_test}


def main():
    repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=repo)
    parser.add_argument("--data-root", type=Path, default=repo / "kwt-data")
    args = parser.parse_args()
    report = audit(args.repo_root, args.data_root)
    path = args.data_root / "reports/kwt-quant-environment.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
