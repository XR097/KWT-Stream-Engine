#!/usr/bin/env python3
"""WP8 KSE entry: KSNUM-012 LayerNorm UVM, KSNUM-014 illegal R/C elaboration, KSSOC-008 SoC peripherals.

  ln          kse_ln_core UVM against wp8_ln_vectors.py data (dual RTL-independent oracle)
  rc          kse_top elaboration matrix: illegal R/C must be rejected, legal controls must elaborate/idle
  soc-periph  delegates to verification/uvm/wp8_kse/wp8_soc_periph_run.py main(argv)

Every vcs/simv/urg runs through codex-shared/vcs_slot.sh. Output directories must be new.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_log import check_log  # noqa: E402
from run_kse_bootstrap import execute as raw_execute  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
WP8 = REPO / 'verification/uvm/wp8_kse'
CM = 'line+cond+fsm+tgl+branch+assert'
LICENSE_RE = re.compile(r'SEC-72|Failed to obtain|-15,\d+|[Ll]icense.*(unavailable|checkout failed)')


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def save(p, v):
    Path(p).write_text(json.dumps(v, indent=2) + '\n')



SLOT_SCRIPT = Path(os.environ.get('VCS_SLOT_WRAPPER', 'vcs'))


def execute(argv, cwd, name, seconds):
    # The shared shell script supplies the memory limit and cross-task lock.
    return raw_execute([str(SLOT_SCRIPT), 'bash', '-lc', 'exec ' + shlex.join(argv)],
                       cwd, name, seconds + 7200)


def write_record(out, inputs, summary, seed, config):
    commands = [json.loads(p.read_text()) for p in sorted(out.rglob('*.command.json'))]
    save(out / 'verification-record.json', {
        'schema': 'strict-final-engine-v1', 'seed': seed, 'config': config,
        'source_sha256': inputs, 'source_manifest': str(out / 'build_path.txt'),
        'commands': commands, 'result': 'PASS' if summary['pass'] else 'FAIL',
        'summary': summary, 'coverage_report': str(out / 'urgReport/dashboard.txt'),
        'negative_coverage_merged': False, 'fsdb_enabled': bool(config.get('waves', False)),
        'scope': 'independent KSE engine only; no shared SRAM/ICB/DMA/CPU',
    })


def licensed(argv, cwd, name, seconds):
    return execute(argv, cwd, name, seconds)


def pdk_memories():
    import yaml
    from kse_resources import memory_config
    return memory_config(REPO)


def rtl_default(name):
    text = (REPO / 'rtl/kse/kse_ln.sv').read_text()
    return int(re.search(r'parameter int\s+' + name + r'\s*=\s*(\d+)', text)[1])


# ---------------------------------------------------------------- KSNUM-012
def cmd_ln(a):
    out, data = a.out.resolve(), a.data.resolve()
    manifest = json.loads((data / 'manifest.json').read_text())
    if sha(data / 'ln_vectors.txt') != manifest['vectors_sha256']:
        raise ValueError('vectors changed')
    for p, h in manifest['inputs'].items():
        if sha(p) != h:
            raise ValueError('oracle input changed: ' + p)
    sources = [REPO / 'rtl/kse/kse_arith.sv', REPO / 'rtl/kse/kse_ln.sv',
               WP8 / 'wp8_ln_if.sv', WP8 / 'wp8_ln_pkg.sv', WP8 / 'tb_wp8_ln.sv']
    controls = [Path(__file__).resolve(), WP8 / 'wp8_ln_vectors.py', data / 'manifest.json', data / 'ln_vectors.txt',
                Path(__file__).with_name('check_log.py'), Path(__file__).with_name('run_kse_bootstrap.py')]
    inputs = {str(p): sha(p) for p in sources + controls}
    out.mkdir(parents=True, exist_ok=False)
    build = a.build.resolve() if a.build else out / 'build'
    cfg = {'lanes': a.lanes, 'nb': a.nb}
    if a.build:
        old = json.loads((build / 'source_manifest.json').read_text())
        if old['files'] != inputs or old['config'] != cfg:
            raise ValueError('build inputs changed')
    else:
        build.mkdir()
        save(build / 'source_manifest.json', {'files': inputs, 'config': cfg, 'top': 'tb_wp8_ln',
                                              'initialization': 'strict four-state; no initreg'})
        (build / 'files.f').write_text('\n'.join(str(p) for p in sources) + '\n')
        (build / 'coverage.hier').write_text('+tree tb_wp8_ln.u_dut\n')
        cmd = ['vcs', '-full64', '-sverilog', '-ntb_opts', 'uvm-1.2', '-timescale=1ns/1ps', '-debug_access+all', '-kdb', '-lca',
               '-assert', 'svaext', '-top', 'tb_wp8_ln', '-pvalue+tb_wp8_ln.LANES=%d' % a.lanes, '-pvalue+tb_wp8_ln.NB=%d' % a.nb,
               '-f', str(build / 'files.f'), '-Mdir=' + str(build / 'csrc'), '-o', str(build / 'simv'),
               '-l', str(build / 'compile.log'), '-cm', CM, '-cm_dir', str(build / 'cov.vdb'), '-cm_hier', str(build / 'coverage.hier')]
        rc = licensed(cmd, build, 'compile', 900)
        txt = (build / 'compile.console.log').read_text(errors='replace')
        warnings = re.findall(r'Warning-\[([^]]+)\]', txt)
        ok = rc == 0 and (build / 'simv').is_file() and all(w == 'LCA_FEATURES_ENABLED' for w in warnings) \
            and not re.search(r'Error-|Fatal-|^Warning\s*:', txt, re.M)
        save(build / 'compile_result.json', {'pass': ok, 'returncode': rc, 'warnings': warnings})
        if not ok:
            print('WP8_LN_COMPILE_FAILED', build)
            return 1
    (out / 'build_path.txt').write_text(str(build) + '\n')
    reports = []
    tokens = manifest['tokens']
    for neg in ([False, True] if a.negative else [False]):
        run = out / ('negative' if neg else 'positive')
        run.mkdir()
        cmd = [str(build / 'simv'), '+UVM_TESTNAME=test_wp8_ln', '+ntb_random_seed=%d' % a.seed, '+VECTORS=' + str(data / 'ln_vectors.txt'),
               '-l', str(run / 'sim.log'), '-cm', CM, '-cm_dir', str(run / 'cov.vdb'), '-cm_name', 'negative' if neg else 'positive']
        if a.waves and not neg:
            cmd += ['+fsdbfile=' + str(run / 'wave.fsdb')]
        if neg:
            cmd += ['+WP8_LN_CORRUPT_EXPECTED']
        rc = licensed(cmd, run, 'sim', 1800)
        log = (run / 'sim.log').read_text(errors='replace') if (run / 'sim.log').exists() else ''
        text = (run / 'sim.console.log').read_text(errors='replace') + log
        (run / 'check_input.log').write_text(text)
        fsdb = run / 'wave.fsdb' if (a.waves and not neg) else None
        result = check_log(run / 'check_input.log', rc, True, fsdb, 'WP8_LN_COMPLETE')
        save(run / 'result.json', result)
        m = re.search(r'\[WP8_LN_COUNT\] sets=(\d+) tokens=(\d+) res_compared=(\d+) out_compared=(\d+) res_bytes=(\d+) out_bytes=(\d+) '
                      r'bad_res=(\d+) bad_out=(\d+) latency_min=(\d+) latency_max=(\d+)', log)
        counts = dict(zip(['sets', 'tokens', 'res_compared', 'out_compared', 'res_bytes', 'out_bytes', 'bad_res', 'bad_out',
                           'latency_min', 'latency_max'], map(int, m.groups()))) if m else None
        bf = re.search(r'\[WP8_LN_DRAIN\] sent=(\d+) done=(\d+) buf_free=(\d+) sets=(\d+)', log)
        complete = bool(counts and counts['tokens'] == tokens == counts['res_compared'] == counts['out_compared']
                        and counts['sets'] == manifest['sets'] and bf and int(bf[3]) == tokens)
        ok = result['verdict'] == 'PASS' and complete and counts['bad_res'] == 0 and counts['bad_out'] == 0 \
            and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)', text, re.M)
        entry = {'negative': neg, 'observed_verdict': result['verdict'], 'counts': counts, 'complete': complete}
        if neg:
            pattern = r'^UVM_ERROR .* \[WP8_LN_OUT\] set=0 token=0 first_channel=0 got=([0-9a-f]{2}) expected=([0-9a-f]{2})$'
            lines = [ln for ln in text.splitlines() if re.fullmatch(pattern, ln)]
            designated = [ln for ln in lines if (lambda g: int(g[1], 16) ^ int(g[2], 16) == 1)(re.fullmatch(pattern, ln))]
            cleaned = '\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*', ln) else ln
                                for ln in text.splitlines() if not re.fullmatch(pattern, ln)) + '\n'
            (run / 'negative-residual.log').write_text(cleaned)
            residual = check_log(run / 'negative-residual.log', rc, True, None, 'WP8_LN_COMPLETE')
            save(run / 'negative-residual.json', residual)
            ok = (len(set(designated)) == 1 and len(set(lines)) == 1 and result['verdict'] == 'FAIL'
                  and result['counts'] == {'UVM_ERROR': 1, 'UVM_FATAL': 0} and residual['verdict'] == 'PASS'
                  and counts is not None and counts['bad_out'] == 1 and counts['bad_res'] == 0 and complete)
            entry.update(designated_line=designated[0] if designated else None, residual_verdict=residual['verdict'])
        entry['accepted'] = ok
        reports.append(entry)
        print(json.dumps(entry), flush=True)
        if not ok:
            break
    urg = -1
    if reports[0]['accepted']:
        urg = licensed(['urg', '-full64', '-dir', str(build / 'cov.vdb'), str(out / 'positive/cov.vdb'),
                        '-report', str(out / 'urgReport'), '-format', 'both'], out, 'urg', 600)
    unchanged = all(sha(p) == h for p, h in inputs.items())
    passed = all(r['accepted'] for r in reports) and len(reports) == (2 if a.negative else 1) and urg == 0 and unchanged
    summary = {'tests': reports, 'inputs_unchanged': unchanged, 'urg_returncode': urg, 'config': cfg,
               'vectors_sha256': manifest['vectors_sha256'], 'pass': passed}
    save(out / 'summary.json', summary)
    write_record(out, inputs, summary, a.seed, dict(cfg, waves=a.waves))
    print('WP8_LN_' + ('DONE' if passed else 'FAILED'), out / 'summary.json')
    return 0 if passed else 1


# ---------------------------------------------------------------- KSNUM-014
RC_CASES = [  # name, R, C, SM, LN, expect_reject
    ('legal_r32_c32_default', 32, 32, 8, 8, False),
    ('legal_r32_c32_lanes1_32', 32, 32, 1, 32, False),
    ('legal_r16_c32', 16, 32, 8, 8, False),
    ('illegal_r32_c16', 32, 16, 16, 16, True),
    ('illegal_r64_c64', 64, 64, 16, 16, True),
    ('illegal_r31_c33', 31, 33, 16, 16, True),
]
RC_MESSAGE = 'kse_top: supported array shapes are R=16/32,C=32'


def cmd_rc(a):
    out = a.out.resolve()
    pdk, mem = pdk_memories()
    rtl = [REPO / 'rtl/kse' / (n + '.sv') for n in ['kse_pkg', 'kse_arith', 'kse_exp_rom', 'kse_gelu_rom', 'kse_post', 'kse_softmax',
                                                    'kse_ln', 'kse_mac_array', 'kse_rowstore', 'kse_pfifo', 'kse_loader', 'kse_mm',
                                                    'kse_pass', 'kse_top']]
    sources = rtl + [Path(mem['v'].format(name=n)) for n in ['RAMSP1024X16', 'RAMSP128X16']] + [WP8 / 'wp8_rc_top.sv']
    inputs = {str(p): sha(p) for p in sources + [pdk, Path(__file__).resolve()]}
    out.mkdir(parents=True, exist_ok=False)
    results = []
    names = a.cases.split(',') if a.cases else [c[0] for c in RC_CASES]
    for name, r, c, sm, ln, reject in [x for x in RC_CASES if x[0] in names]:
        d = out / name
        d.mkdir()
        (d / 'files.f').write_text('\n'.join(str(p) for p in sources) + '\n')
        cmd = ['vcs', '-full64', '-sverilog', '-timescale=1ns/1ps', '-lca', '-top', 'wp8_rc_top',
               '+define+WP8_R=%d' % r, '+define+WP8_C=%d' % c, '+define+WP8_SM=%d' % sm, '+define+WP8_LN=%d' % ln,
               '-f', str(d / 'files.f'), '-Mdir=' + str(d / 'csrc'), '-o', str(d / 'simv'), '-l', str(d / 'compile.log')]
        cmd += ['+define+' + n for n in mem['sim_defines']] + mem.get('sim_opts', [])
        rc = licensed(cmd, d, 'compile', 900)
        ctext = (d / 'compile.console.log').read_text(errors='replace')
        entry = {'case': name, 'R': r, 'C': c, 'SM_LANES': sm, 'LN_LANES': ln, 'expect_reject': reject, 'compile_rc': rc,
                 'simv': (d / 'simv').is_file()}
        msg_compile = ctext.count(RC_MESSAGE)
        errors = re.findall(r'^(Error-\[[^\]]+\].*)$', ctext, re.M)
        entry.update(message_in_compile=msg_compile, compile_error_tags=sorted(set(re.findall(r'Error-\[([^\]]+)\]', ctext))))
        stext = ''
        if entry['simv']:
            src = licensed([str(d / 'simv'), '-l', str(d / 'sim.log')], d, 'sim', 300)
            stext = (d / 'sim.console.log').read_text(errors='replace')
            entry.update(sim_rc=src, message_in_sim=stext.count(RC_MESSAGE),
                         idle=re.search(r'WP8_RC_IDLE .*bad_cycles=(\d+)', stext) and int(re.search(r'bad_cycles=(\d+)', stext)[1]))
        if reject:
            # Accept only: compile fails, no simv, the spec message is reported, and every Error is attributable to it.
            entry['accepted'] = (rc != 0 and not entry['simv'] and msg_compile >= 1 and len(errors) >= 1)
            entry['first_error'] = errors[0][:300] if errors else None
        else:
            entry['accepted'] = (rc == 0 and entry['simv'] and msg_compile == 0 and not errors
                                 and entry.get('message_in_sim') == 0 and entry.get('idle') == 0
                                 and 'WP8_RC_COMPLETE TEST PASSED' in stext)
        results.append(entry)
        print(json.dumps(entry), flush=True)
    unchanged = all(sha(p) == h for p, h in inputs.items())
    passed = all(e['accepted'] for e in results) and unchanged and len(results) == len(names)
    save(out / 'summary.json', {'cases': results, 'inputs': inputs, 'inputs_unchanged': unchanged, 'pass': passed,
                                'spec': 'current RTL: R=16/32, C=32; LANES 1..32 legal'})
    print('WP8_RC_' + ('DONE' if passed else 'FAILED'), out / 'summary.json')
    return 0 if passed else 1


def main():
    if len(sys.argv) > 1 and sys.argv[1] == 'soc-periph':
        sys.path.insert(0, str(WP8))
        import wp8_soc_periph_run
        return wp8_soc_periph_run.main(sys.argv[2:])
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('ln')
    p.add_argument('--data', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--build', type=Path)
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--lanes', type=int, default=rtl_default('LANES'))
    p.add_argument('--nb', type=int, default=rtl_default('NB'))
    p.add_argument('--negative', action='store_true')
    p.add_argument('--waves', action='store_true')
    p = sub.add_parser('rc')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--cases', help='comma-separated subset of: ' + ','.join(c[0] for c in RC_CASES))
    sub.add_parser('soc-periph', help='see verification/uvm/wp8_kse/wp8_soc_periph_run.py --help')
    a = ap.parse_args()
    return cmd_ln(a) if a.cmd == 'ln' else cmd_rc(a)


if __name__ == '__main__':
    raise SystemExit(main())
