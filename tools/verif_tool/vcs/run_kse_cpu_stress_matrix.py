#!/usr/bin/env python3
"""Serial strict-final real-E203 sample0/12/23 x seed7/42 concurrency matrix."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

from run_kse_cpu_stress import metrics, traffic_ok
from run_kse_network import REPO, CM, sha, save
from run_kse_bootstrap import execute

RUNNER = Path(__file__).with_name('run_kse_cpu_stress.py').resolve()


def check_case(case):
    failures = []
    if not (case / 'summary.json').is_file():
        return {'pass': False, 'case': str(case), 'failures': ['missing runner summary']}
    s = json.loads((case / 'summary.json').read_text())
    if not s.get('pass') or not s.get('inputs_unchanged') or s.get('urg_returncode') != 0:
        failures.append('runner verdict/integrity/URG not accepted')
    result = json.loads((case / 'positive/result.json').read_text())
    if result.get('verdict') != 'PASS' or result.get('counts') != {'UVM_ERROR': 0, 'UVM_FATAL': 0}:
        failures.append('positive UVM result not accepted')
    log = (case / 'positive/sim.log').read_text(errors='replace')
    m = metrics(log)
    if not traffic_ok(m) or 'KSE_NETWORK_COMPLETE' not in log or 'TEST PASSED' not in log:
        failures.append('completion/CPU traffic metrics not accepted')
    manifest = json.loads((case / 'source_manifest.json').read_text())
    mismatches = [p for group in ['files', 'firmware_artifacts'] for p, h in manifest[group].items()
                  if not Path(p).is_file() or sha(Path(p)) != h]
    if mismatches:
        failures.append('source/firmware SHA256 mismatch')
    if not (case / 'urgReport/dashboard.txt').is_file():
        failures.append('missing coverage dashboard')
    return {'pass': not failures, 'case': str(case), 'failures': failures, 'metrics': s['metrics'],
            'urg_rc': s['urg_returncode'], 'negative_controls': [t['negative_hit'] for t in s['tests'] if t['negative_hit']]}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', required=True, type=Path)
    ap.add_argument('--data', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--samples', type=int, nargs='+', default=[0, 12, 23])
    ap.add_argument('--seeds', type=int, nargs='+', default=[7, 42])
    ap.add_argument('--jobs', type=int, choices=[1], default=1, help='serial only; every tool uses shared slot')
    ap.add_argument('--waves', action='store_true')
    ap.add_argument('--negative', action='store_true', help='data and arbitration controls on first case')
    ap.add_argument('--baseline', action='store_true')
    a = ap.parse_args()
    a.build, a.data, a.out = a.build.resolve(), a.data.resolve(), a.out.resolve()
    if not (a.build / 'simv').is_file() or not a.data.is_dir():
        ap.error('build/data missing')
    if len(set(a.samples)) != len(a.samples) or len(set(a.seeds)) != len(a.seeds):
        ap.error('duplicate samples/seeds')
    a.out.mkdir(parents=True, exist_ok=False)
    files = [Path(__file__).resolve(), RUNNER]
    inputs = {str(p): sha(p) for p in files}
    results = []
    commands = []
    for i, (sample, seed) in enumerate((s, seed) for s in a.samples for seed in a.seeds):
        case = a.out / f'sample{sample}-seed{seed}'
        cmd = [sys.executable, str(RUNNER), '--build', str(a.build), '--data', str(a.data),
               '--out', str(case), '--sample', str(sample), '--seed', str(seed)]
        if a.waves:
            cmd.append('--waves')
        if a.negative and i == 0:
            cmd.append('--negative')
        if a.baseline:
            cmd.append('--baseline')
        started = time.monotonic()
        with (a.out / f'sample{sample}-seed{seed}.runner.log').open('w') as log:
            proc = subprocess.run(cmd, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, check=False)
        checked = check_case(case)
        checked.update(sample=sample, seed=seed, runner_rc=proc.returncode,
                       wall_s=round(time.monotonic() - started, 2))
        if proc.returncode:
            checked['pass'] = False
            checked['failures'].append(f'runner rc={proc.returncode}')
        commands.append(cmd)
        results.append(checked)
        save(a.out / 'progress.json', {'cases': results, 'expected': len(a.samples) * len(a.seeds)})
        print(json.dumps(checked), flush=True)
    urg_rc = -1
    if all(r['pass'] for r in results):
        urg_rc = execute(['urg', '-full64', '-dir', str(a.build / 'cov.vdb')] +
                         [str(Path(r['case']) / 'positive/cov.vdb') for r in results] +
                         ['-report', str(a.out / 'urgReport'), '-format', 'both'], a.out, 'urg', 240)
    passed = (bool(results) and all(r['pass'] for r in results) and urg_rc == 0
              and (a.out / 'urgReport/dashboard.txt').is_file()
              and all(sha(Path(p)) == h for p, h in inputs.items()))
    summary = {'pass': passed, 'cases': results, 'commands': commands, 'source_sha256': inputs,
               'samples': a.samples, 'seeds': a.seeds, 'jobs': 1, 'urg_rc': urg_rc,
               'build': str(a.build), 'data': str(a.data), 'scope': 'six-case limited real-E203 CPU concurrency matrix'}
    save(a.out / 'summary.json', summary)
    save(a.out / 'verification-record.json', summary)
    print('KSE_CPU_STRESS_MATRIX_' + ('PASS' if passed else 'FAIL'), a.out / 'summary.json', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
