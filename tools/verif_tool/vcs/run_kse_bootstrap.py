#!/usr/bin/env python3
"""Compile frozen KSE subsystem RTL, run UVM smoke and a scoreboard negative control.

All outputs stay below --out (default project/run/uvm). No RTL rewriting.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import time

import yaml

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_log import check_log


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_negative(run, output, rc, report):
    """Allow only the deliberately corrupted ID read; reject other failures."""
    designated = re.compile(r'^UVM_ERROR .* \[KSE_SB\] port=0 addr=11000000 '
                            r'got=4b534531/0 expected=4b534530/0$')
    observed = [line for line in output.splitlines() if designated.fullmatch(line)]
    # Console and -l logs can contain the same message twice. Counts must still
    # report one error, and every other diagnostic must independently pass.
    cleaned = '\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*', line)
                        else line for line in output.splitlines()
                        if not designated.fullmatch(line)) + '\n'
    path = run / 'negative-residual.log'
    path.write_text(cleaned)
    residual = check_log(path, rc, True, run / 'wave.fsdb', 'KSE_TEST_COMPLETE')
    (run / 'negative-residual.json').write_text(json.dumps(residual, indent=2) + '\n')
    return (bool(observed) and report['verdict'] == 'FAIL' and
            report['counts'] == {'UVM_ERROR': 1, 'UVM_FATAL': 0} and
            residual['verdict'] == 'PASS')


def _execute(argv, cwd, name, seconds):
    meta = {'argv': argv, 'cwd': str(cwd), 'timeout_seconds': seconds,
            'started_at': datetime.datetime.now().astimezone().isoformat()}
    (cwd / (name + '.cmd')).write_text(shlex.join(argv) + '\n')
    start = time.monotonic()
    with (cwd / (name + '.console.log')).open('wb') as log:
        proc = subprocess.Popen(argv, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            rc = 124
    meta.update(returncode=rc, elapsed_seconds=round(time.monotonic() - start, 3),
                finished_at=datetime.datetime.now().astimezone().isoformat())
    (cwd / (name + '.command.json')).write_text(json.dumps(meta, indent=2) + '\n')
    return rc


def execute(argv, cwd, name, seconds):
    from kse_resources import guarded_execute
    return guarded_execute(_execute, argv, cwd, name, seconds)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=REPO / 'run/uvm')
    ap.add_argument('--seed', type=int, default=1)
    a = ap.parse_args()
    job = a.out.resolve() / ('kse-bootstrap-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    build = job / 'build'
    build.mkdir(parents=True, exist_ok=False)
    print('JOB=' + str(job), flush=True)
    from kse_resources import memory_config
    pdk_file, mem = memory_config(REPO)
    macro_names = ['RAMSP128X16', 'RAMSP1024X16', 'RAMSP4096X16']
    macros = []
    for name in macro_names:
        if name not in mem['names']:
            raise ValueError('macro is not in PDK configuration: ' + name)
        macros.append(Path(mem['v'].format(name=name)))
    kse = ['kse_pkg', 'kse_arith', 'kse_exp_rom', 'kse_gelu_rom', 'kse_post',
           'kse_softmax', 'kse_ln', 'kse_mac_array', 'kse_rowstore', 'kse_pfifo',
           'kse_loader', 'kse_mm', 'kse_pass', 'kse_top']
    soc = ['kse_soc_fifo', 'kse_sram_ctrl', 'kse_shared_sram', 'kse_sys_bus', 'kse_eng_icb', 'kse_accel_sys']
    tb = REPO / 'verification/uvm/kse'
    sources = ([REPO / 'rtl/kse' / (n + '.sv') for n in kse] +
               [REPO / 'rtl/kse_soc' / (n + '.sv') for n in soc] + macros +
               [tb / n for n in ['kse_icb_if.sv', 'kse_bootstrap_pkg.sv', 'tb_kse_bootstrap.sv']])
    from kse_resources import e203_sources
    e = e203_sources()
    sources += [e / 'general' / n for n in ['sirv_gnrl_icbs.v', 'sirv_gnrl_dffs.v', 'sirv_gnrl_bufs.v']]
    for path in sources:
        if not path.is_file():
            raise FileNotFoundError(path)
    inputs = {str(p): digest(p) for p in sources + [pdk_file, Path(__file__).resolve(),
                                                   Path(__file__).with_name('check_log.py'),
                                                   Path(__file__).with_name('kse_resources.py')]}
    manifest = {'git_head': subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
                'files': inputs, 'seed': a.seed, 'top': 'tb_kse_bootstrap',
                'macro_models': macro_names, 'pdk_configuration': str(pdk_file),
                'parameters': 'kse_accel_sys production defaults; no overrides',
                'initialization': 'strict four-state, no initreg'}
    (build / 'source_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (build / 'files.f').write_text('\n'.join(str(p) for p in sources) + '\n')
    (build / 'coverage.hier').write_text('+tree tb_kse_bootstrap.dut\n')
    # Verdi 2024.09+ rejects legacy -P novas.tab/pli.a when debug_access is
    # enabled. VCS loads its matching FSDB integration from VERDI_HOME.
    if not Path(os.environ['VERDI_HOME']).is_dir():
        raise ValueError('VERDI_HOME must select the installed Verdi tree')
    opts = ['vcs', '-full64', '-sverilog', '-ntb_opts', 'uvm-1.2', '-timescale=1ns/1ps',
            '-kdb', '-debug_access+all', '-assert', 'svaext', '-lca',
            '-top', 'tb_kse_bootstrap', '-f', str(build / 'files.f'),
            '-Mdir=' + str(build / 'csrc'), '-o', str(build / 'simv'), '-l', str(build / 'compile.log'),
            '-cm', 'line+cond+fsm+tgl+branch+assert', '-cm_dir', str(build / 'cov.vdb'),
            '-cm_hier', str(build / 'coverage.hier')]
    opts += ['+define+' + n for n in mem['sim_defines']] + mem.get('sim_opts', [])
    rc = execute(opts, build, 'compile', 1200)
    if rc or not (build / 'simv').is_file():
        print('KSE_COMPILE_FAILED ' + str(build / 'compile.console.log'))
        return 1
    reports = []
    for negative in [False, True]:
        run = job / ('negative-scoreboard' if negative else 'positive')
        run.mkdir()
        argv = [str(build / 'simv'), '+UVM_TESTNAME=test_kse_bootstrap',
                '+ntb_random_seed=' + str(a.seed), '+UVM_VERBOSITY=UVM_LOW',
                '+fsdbfile=' + str(run / 'wave.fsdb'),
                '-cm', 'line+cond+fsm+tgl+branch+assert', '-cm_dir', str(run / 'cov.vdb'),
                '-cm_name', 'negative' if negative else 'positive', '-l', str(run / 'sim.log')]
        if negative:
            argv += ['+SB_CORRUPT_EXPECTED']
        rc = execute(argv, run, 'sim', 180)
        # Check the simulator's complete output, including early startup errors.
        output = (run / 'sim.console.log').read_bytes()
        if (run / 'sim.log').exists():
            output += (run / 'sim.log').read_bytes()
        (run / 'check_input.log').write_bytes(output)
        report = check_log(run / 'check_input.log', rc, True, run / 'wave.fsdb', 'KSE_TEST_COMPLETE')
        (run / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        if negative:
            # A different failure (tool/license/timeout) is not checker evidence.
            accepted = validate_negative(run, output.decode(errors='replace'), rc, report)
        else:
            accepted = report['verdict'] == 'PASS'
        reports.append({'run': str(run), 'kind': 'negative_control' if negative else 'positive',
                        'accepted': accepted, 'observed_verdict': report['verdict']})
        print(json.dumps(reports[-1]), flush=True)
    # Negative-control coverage is deliberately excluded from the positive report.
    rc = execute(['urg', '-full64', '-dir', str(build / 'cov.vdb'), str(job / 'positive/cov.vdb'),
                  '-report', str(job / 'urgReport'), '-format', 'both'], job, 'urg', 180)
    unchanged = all(digest(Path(p)) == h for p, h in inputs.items())
    summary = {'tests': reports, 'urg_returncode': rc,
               'urg_report_present': (job / 'urgReport').is_dir(), 'inputs_unchanged': unchanged,
               'scope': 'idle reset/MMIO and sequential CPU/loader SRAM accesses only; no inference, DMA command or E203 execution'}
    summary['pass'] = (all(t['accepted'] for t in reports) and rc == 0 and summary['urg_report_present'] and unchanged)
    (job / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('KSE_BOOTSTRAP_' + ('DONE' if summary['pass'] else 'FAILED') + ' ' + str(job / 'summary.json'))
    return 0 if summary['pass'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
