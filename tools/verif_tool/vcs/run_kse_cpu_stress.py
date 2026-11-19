#!/usr/bin/env python3
"""Real E203 strict-final CPU scratch concurrency, isolated controls, and URG."""
import argparse
import json
from pathlib import Path
import re

from check_log import check_log
from run_kse_bootstrap import execute
from run_kse_network import REPO, CM, sha, save, validate_data


def fields(text, tag):
    lines = re.findall(r'\[' + re.escape(tag) + r'\]\s+([^\n]+)', text)
    if not lines:
        return {}
    payload = next((line for line in reversed(lines) if '=' in line), '')
    return {k: float(v) if '.' in v else int(v) for k, v in
            re.findall(r'(\w+)=([0-9]+(?:\.[0-9]+)?)', payload)}


def metrics(text):
    cpu, net = fields(text, 'CPU_STRESS'), fields(text, 'NETWORK_SAMPLE')
    port = re.search(r'\[SRAM_PORT\] port=0 ([^\n]+)', text)
    p0 = fields('[P] ' + port[1], 'P') if port else {}
    return {'cpu': cpu, 'network': net, 'port0': p0,
            'delta_vs_163328': net.get('window', 0) - 163328}


def traffic_ok(m):
    c, p, n = m['cpu'], m['port0'], m['network']
    return bool(c and p and n and c['req'] == c['rsp'] == p['req'] == p['rsp']
                and p['cancelled'] == 0 and c['scratch_reads'] >= 32
                and c['active_reads'] > 0 and c['active_writes'] > 0
                and c['triple_cycles'] == n['triple_requests'] > 0
                and c['word_writes'] > 0 and c['byte_writes'] > 0 and c['half_writes'] > 0
                and c['wait_max'] <= 200000 and n['write'] == n['ack'] == 1584
                and n['commands'] == n['events'] == 12)


def run_sim(a, build, data, out, name, hexfile, inputs, extra=(), target=None, reference=False):
    run = out / name
    run.mkdir()
    cmd = [str(build / 'simv'), '+UVM_TESTNAME=test_kse_cpu_stress', '+UVM_VERBOSITY=UVM_LOW',
           '+ntb_random_seed=' + str(a.seed), '+DATA=' + str(data), '+FIRST=' + str(a.sample),
           '+COUNT=1', '+STALL_MODE=' + str(a.stall_mode), '+FW=' + str(hexfile),
           '+FW_WORDS=' + str(len(hexfile.read_text().splitlines())),
           '+METRICS=' + str(run / 'network_metrics.tsv'), '-l', str(run / 'sim.log'),
           '-cm', CM, '-cm_dir', str(run / 'cov.vdb'), '-cm_name', name] + list(extra)
    if a.waves:
        cmd += ['+fsdbfile=' + str(run / 'wave.fsdb')]
    rc = execute(cmd, run, 'sim', 1800)
    # Keep console diagnostics too, but use the canonical simulator log for
    # exact message cardinality (console and -l repeat the same UVM message).
    raw = (run / 'sim.console.log').read_bytes()
    sim = (run / 'sim.log').read_bytes() if (run / 'sim.log').is_file() else raw
    (run / 'check_input.log').write_bytes(raw + sim)
    result = check_log(run / 'check_input.log', rc, True,
                       run / 'wave.fsdb' if a.waves else None, 'KSE_NETWORK_COMPLETE')
    save(run / 'result.json', result)
    text = sim.decode(errors='replace')
    m = metrics(text)
    accepted = result['verdict'] == 'PASS' and 'TEST PASSED' in text
    accepted = accepted and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)', text, re.M)
    if not reference:
        accepted = accepted and traffic_ok(m)
    negative = None
    if target:
        designated = re.compile(r'^UVM_ERROR .* \[' + re.escape(target) + r'\] .+$')
        errors = [s for s in text.splitlines() if designated.fullmatch(s)]
        residual_text = '\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*', s) else s
                                  for s in (raw + sim).decode(errors='replace').splitlines()
                                  if not designated.fullmatch(s)) + '\n'
        (run / 'negative-residual.log').write_text(residual_text)
        residual = check_log(run / 'negative-residual.log', rc, True,
                             run / 'wave.fsdb' if a.waves else None, 'KSE_NETWORK_COMPLETE')
        save(run / 'negative-residual.json', residual)
        accepted = (result['verdict'] == 'FAIL' and result['counts'] == {'UVM_ERROR': 1, 'UVM_FATAL': 0}
                    and len(errors) == 1 and residual['verdict'] == 'PASS' and traffic_ok(m))
        negative = {'target': target, 'hits': len(errors), 'messages': errors,
                    'residual_verdict': residual['verdict'], 'accepted': accepted,
                    'injection_scope': 'checker observation only; DUT and firmware unchanged'}
        save(run / 'negative-acceptance.json', negative)
    record = {'pass': bool(accepted), 'sample': a.sample, 'seed': a.seed, 'stall_mode': a.stall_mode,
              'source_sha256': inputs, 'command': json.loads((run / 'sim.command.json').read_text()),
              'negative_hit': negative, 'urg_rc': None, 'metrics': m}
    save(run / 'verification-record.json', record)
    print(json.dumps({'case': name, 'sample': a.sample, 'seed': a.seed, 'pass': bool(accepted),
                      'metrics': m}), flush=True)
    return record


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--build', type=Path, required=True)
    ap.add_argument('--data', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--sample', type=int, default=0)
    ap.add_argument('--seed', type=int, default=7)
    ap.add_argument('--stall-mode', type=int, choices=[0, 1], default=1)
    ap.add_argument('--waves', action='store_true')
    ap.add_argument('--negative', action='store_true', help='isolated CPU data and arbiter observation mutations')
    ap.add_argument('--negative-output', action='store_true', help='additional output golden mutation')
    ap.add_argument('--baseline', action='store_true', help='also run production WFI firmware with identical loader seed/stalls')
    a = ap.parse_args()
    if not 0 <= a.sample < 24 or not 0 <= a.seed <= 0xffffffff:
        ap.error('sample must be 0..23; seed must fit uint32')
    build, data, out = a.build.resolve(), a.data.resolve(), a.out.resolve()
    source = json.loads((build / 'source_manifest.json').read_text())
    cfg = source['configuration']
    if cfg['kind'] != 'soc' or not cfg.get('cpu_observer') or validate_data(data) != cfg['data_manifest_sha256']:
        raise ValueError('need matching dedicated strict CPU SoC build/data')
    if not json.loads((build / 'compile_result.json').read_text())['pass']:
        raise ValueError('build did not pass compile acceptance')
    inputs = dict(cfg['files'])
    if any(sha(Path(p)) != h for p, h in inputs.items()):
        raise ValueError('compiled/control input changed')
    if any(sha(Path(p)) != h for p, h in source['firmware_artifacts'].items()):
        raise ValueError('production firmware artifact changed')
    out.mkdir(parents=True, exist_ok=False)
    fw = out / 'firmware'
    fw.mkdir()
    compiler = Path('${RISCV_PREFIX:-riscv-none-elf-}gcc')
    prefix = str(compiler)[:-3]
    main_c = REPO / 'verification/uvm/kse/kse_cpu_stress.c'
    inputs.update({str(p): sha(p) for p in [main_c, Path(__file__).resolve(),
                   Path(__file__).with_name('run_kse_cpu_stress_matrix.py'),
                   Path(__file__).with_name('check_log.py')]})
    elf = fw / 'kse_stress.elf'
    cmd = [str(compiler), '-march=rv32imac_zicsr', '-mabi=ilp32', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
           '-DKSE_STRESS_SEED=' + str(a.seed) + 'u', '-std=c11', '-ffreestanding', '-fno-builtin',
           '-fno-common', '-msmall-data-limit=0', '-mno-relax', '-nostdlib', '-nostartfiles', '-static',
           '-Wl,-T,' + str(REPO / 'firmware/kse/link.ld') + ',--no-relax,--build-id=none',
           str(REPO / 'firmware/kse/start.S'), str(main_c), '-o', str(elf)]
    commands = [cmd, [prefix + 'objcopy', '-O', 'binary', str(elf), str(fw / 'kse_stress.bin')],
                [prefix + 'objdump', '-d', str(elf)],
                ['python3', str(REPO / 'tools/kse_soc/bin2itcm.py'), str(fw / 'kse_stress.bin'), str(fw / 'kse_stress.itcm.hex')]]
    for i, cmd in enumerate(commands):
        if execute(cmd, out, 'firmware-' + str(i), 180):
            raise RuntimeError('stress firmware build failed')
    fw_hashes = {str(p): sha(p) for p in fw.iterdir() if p.is_file()}
    save(out / 'source_manifest.json', {'base_build_manifest': str(build / 'source_manifest.json'),
         'base_build_manifest_sha256': sha(build / 'source_manifest.json'), 'files': inputs,
         'firmware_artifacts': fw_hashes, 'data_manifest_sha256': validate_data(data),
         'purpose': 'real CPU word/byte/halfword scratch self-checks concurrent with strict single-port KSE'})
    hexfile = fw / 'kse_stress.itcm.hex'
    records = [run_sim(a, build, data, out, 'positive', hexfile, inputs)]
    if records[0]['pass']:
        for name, flags, target in ([('negative-cpu-data', ['+CPU_CORRUPT_OBSERVED'], 'CPU_DATA'),
                                    ('negative-arbitration', ['+CHECKER_MUTATION=arbitration'], 'ARBITER')] if a.negative else []):
            records.append(run_sim(a, build, data, out, name, hexfile, inputs, flags, target))
        if a.negative_output:
            records.append(run_sim(a, build, data, out, 'negative-output', hexfile, inputs,
                                   ['+CORRUPT_OUTPUT_EXPECTED'], 'NETWORK_GOLDEN'))
        if a.baseline:
            baseline = run_sim(a, build, data, out, 'baseline', build / 'firmware/kse_fw.itcm.hex', inputs,
                               ['+CPU_REFERENCE'], reference=True)
            records.append(baseline)
            records[0]['metrics']['delta_vs_matched_baseline'] = (records[0]['metrics']['network']['window'] -
                                                                baseline['metrics']['network']['window'])
    urg_rc = -1
    if records[0]['pass']:
        urg_rc = execute(['urg', '-full64', '-dir', str(build / 'cov.vdb'), str(out / 'positive/cov.vdb'),
                          '-report', str(out / 'urgReport'), '-format', 'both'], out, 'urg', 240)
    unchanged = (all(sha(Path(p)) == h for p, h in inputs.items())
                 and all(sha(Path(p)) == h for p, h in fw_hashes.items())
                 and all(sha(Path(p)) == h for p, h in source['firmware_artifacts'].items())
                 and validate_data(data) == cfg['data_manifest_sha256'])
    passed = all(r['pass'] for r in records) and urg_rc == 0 and unchanged and (out / 'urgReport/dashboard.txt').is_file()
    for r in records:
        r['urg_rc'] = urg_rc if r['negative_hit'] is None else None
        save(Path(r['command']['cwd']) / 'verification-record.json', r)
    summary = {'pass': bool(passed), 'cpu_traffic_checked': traffic_ok(records[0]['metrics']),
               'urg_returncode': urg_rc, 'inputs_unchanged': unchanged, 'tests': records,
               'metrics': records[0]['metrics'], 'source_sha256': inputs, 'sample': a.sample, 'seed': a.seed,
               'scope': 'selected real E203 SoC sample; strict DMA > loader > CPU; no fairness guarantee'}
    save(out / 'summary.json', summary)
    save(out / 'verification-record.json', summary)
    print('KSE_CPU_STRESS_' + ('DONE' if passed else 'FAILED'), out / 'summary.json', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
