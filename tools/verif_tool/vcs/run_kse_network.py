#!/usr/bin/env python3
"""VCS/UVM real KSE MMIO/DMA/IRQ subsystem or E203 SoC, frozen all-24 data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re

import yaml
from check_log import check_log
from run_kse_bootstrap import execute

REPO = Path(__file__).resolve().parents[3]
CM = 'line+cond+fsm+tgl+branch+assert'


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def save(p, data):
    p.write_text(json.dumps(data, indent=2) + '\n')


def validate_data(path):
    m = json.loads((path / 'data_manifest.json').read_text())
    if m['candidate'] != 'e3521354cc15f0877aef_middle' or m['samples'] != 24 or m['layers'] != 12:
        raise ValueError('unexpected candidate/samples/layers')
    if [t['sample'] for t in m['tasks']] != list(range(24)):
        raise ValueError('samples missing, duplicated or reordered')
    if sha(Path(m['source_manifest'])) != m['source_manifest_sha256']:
        raise ValueError('source binding changed')
    for group in ['inputs', 'outputs']:
        for name, spec in m[group].items():
            p = Path(name)
            if p.stat().st_size != spec['bytes'] or sha(p) != spec['sha256']:
                raise ValueError('input changed: ' + name)
    for i in range(24):
        for suffix, n in [('img', 80592), ('out', 1584)]:
            p = path / f'sample_{i:02d}_{suffix}.hex'
            if str(p) not in m['outputs'] or len(p.read_text().splitlines()) != n:
                raise ValueError('missing/incorrect task payload')
    return sha(path / 'data_manifest.json')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--kind', choices=['subsystem', 'soc'], required=True)
    ap.add_argument('--out', required=True, type=Path)
    ap.add_argument('--data', required=True, type=Path)
    ap.add_argument('--build', type=Path)
    ap.add_argument('--first', type=int, default=0)
    ap.add_argument('--count', type=int, default=1)
    ap.add_argument('--step', type=int, default=1)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--stall-mode', type=int, choices=[0, 1], default=0)
    ap.add_argument('--waves', action='store_true')
    ap.add_argument('--negative-output', action='store_true')
    ap.add_argument('--seconds', type=int, default=2400)
    ap.add_argument('--watchdog-cycles', type=int, default=12000000)
    a = ap.parse_args()
    if a.first < 0 or a.count < 1 or a.step<1 or a.first + (a.count-1)*a.step >= 24:
        ap.error('sample range must be inside 0..23')
    out = a.out.resolve()
    data = a.data.resolve()
    data_hash = validate_data(data)
    out.mkdir(parents=True, exist_ok=False)
    top = 'tb_kse_' + a.kind + '_uvm'
    from kse_resources import memory_config
    pdk, mem = memory_config(REPO)
    macros = ['RAMSP1024X16', 'RAMSP128X16', 'RAMSP4096X16']
    if any(n not in mem['names'] for n in macros):
        raise ValueError('unconfigured SRAM model')
    sources = [REPO / 'rtl/kse' / (n + '.sv') for n in
               ['kse_pkg', 'kse_arith', 'kse_exp_rom', 'kse_gelu_rom', 'kse_post', 'kse_softmax',
                'kse_ln', 'kse_mac_array', 'kse_rowstore', 'kse_pfifo', 'kse_loader', 'kse_mm', 'kse_pass', 'kse_top']]
    sources += [REPO / 'rtl/kse_soc' / (n + '.sv') for n in
                ['kse_soc_fifo', 'kse_sram_ctrl', 'kse_shared_sram', 'kse_sys_bus', 'kse_eng_icb', 'kse_accel_sys']]
    incdirs = []
    controls = [Path(__file__).with_name('kse_resources.py'), pdk, Path(__file__).resolve(), Path(__file__).with_name('check_log.py'),
                Path(__file__).with_name('run_kse_bootstrap.py'), Path(__file__).with_name('prepare_kse_network.py')]
    from kse_resources import e203_sources
    e = e203_sources()
    compiler = None
    if a.kind == 'soc':
        replaced = {'soc/e203_soc_top.v', 'subsys/e203_subsys_top.v', 'subsys/e203_subsys_main.v',
                    'subsys/e203_subsys_mems.v', 'subsys/e203_subsys_plic.v', 'perips/sirv_plic_top.v',
                    'perips/apb_uart/apb_uart.v', 'general/sirv_gnrl_ram.v'}
        sources = sorted(p for p in e.rglob('*.v') if str(p.relative_to(e)) not in replaced) + sources
        sources += [REPO / 'rtl/kse_soc' / (n + '.v') for n in
                    ['kse_sirv_plic_top', 'kse_e203_subsys_plic', 'kse_e203_subsys_mems', 'kse_e203_subsys_main',
                     'kse_e203_subsys_top', 'kse_e203_soc_top', 'apb_uart', 'kse_tcm_gnrl_ram']]
        incdirs = [e / n for n in ['core', 'perips', 'perips/apb_i2c']]
        controls += sorted((e / 'core').glob('*.v'))
        controls += [REPO / 'firmware/kse' / n for n in ['Makefile', 'start.S', 'main.c', 'kse_soc.h', 'link.ld']]
        controls += [REPO / 'tools/kse_soc/bin2itcm.py']
        compiler = Path('${RISCV_PREFIX:-riscv-none-elf-}gcc')
        controls.append(compiler)
    if a.kind != 'soc':
        sources += [e / 'general' / n for n in ['sirv_gnrl_icbs.v', 'sirv_gnrl_dffs.v', 'sirv_gnrl_bufs.v', 'sirv_gnrl_xchecker.v']]
    sources += [Path(mem['v'].format(name=n)) for n in macros]
    sources += [REPO / 'verification/uvm/kse' / n for n in
                ['kse_integration_if.sv', 'kse_integration_pkg.sv', 'kse_network_pkg.sv', top + '.sv']]
    inputs = {str(p): sha(p) for p in sources + controls}
    config = {'files': inputs, 'kind': a.kind, 'top': top, 'parameters': 'production defaults, DMA > loader > CPU; REL_LAG=0; R32 C32 PF128 SM8 LN8',
              'initialization': 'strict four-state, no initreg; shared SRAM/DTCM not precleared; SoC ITCM only loaded during reset',
              'data_manifest_sha256': data_hash}
    build = a.build.resolve() if a.build else out / 'build'
    if a.build:
        old = json.loads((build / 'source_manifest.json').read_text())
        if old['configuration'] != config or not (build / 'simv').is_file():
            raise ValueError('build inputs/configuration changed')
        for name, h in old['firmware_artifacts'].items():
            if sha(Path(name)) != h:
                raise ValueError('firmware artifact changed')
    else:
        build.mkdir()
        firmware_artifacts = {}
        if a.kind == 'soc':
            fw = build / 'firmware'
            rc = execute(['make', '-C', str(REPO / 'firmware/kse'), 'BUILD=' + str(fw)], build, 'firmware', 180)
            if rc or not (fw / 'kse_fw.itcm.hex').is_file():
                print('KSE_NETWORK_FIRMWARE_FAILED', build)
                return 1
            firmware_artifacts = {str(p): sha(p) for p in sorted(fw.iterdir()) if p.is_file()}
            execute([str(compiler), '--version'], build, 'compiler-version', 20)
        save(build / 'source_manifest.json', {'configuration': config, 'firmware_artifacts': firmware_artifacts})
        (build / 'files.f').write_text('\n'.join(['+incdir+' + str(p) for p in incdirs] + [str(p) for p in sources]) + '\n')
        (build / 'coverage.hier').write_text('+tree ' + top + '\n')
        cmd = ['vcs', '-full64', '-sverilog', '-ntb_opts', 'uvm-1.2', '-timescale=1ns/1ps',
               '-kdb', '-debug_access+all', '-assert', 'svaext', '-lca', '-top', top,
               '-f', str(build / 'files.f'), '-Mdir=' + str(build / 'csrc'), '-o', str(build / 'simv'),
               '-l', str(build / 'compile.log'), '-cm', CM, '-cm_dir', str(build / 'cov.vdb'),
               '-cm_hier', str(build / 'coverage.hier')]
        cmd += ['+define+' + n for n in mem['sim_defines']] + mem.get('sim_opts', [])
        rc = execute(cmd, build, 'compile', 1200)
        text = (build / 'compile.console.log').read_text(errors='replace')
        warnings = re.findall(r'Warning-\[([^]]+)\]', text)
        passed = (rc == 0 and (build / 'simv').is_file() and all(n == 'LCA_FEATURES_ENABLED' for n in warnings)
                  and not re.search(r'Error-|Fatal-|^Warning\s*:', text, re.M))
        save(build / 'compile_result.json', {'pass': passed, 'returncode': rc, 'warnings': warnings})
        save(out / 'verification-record.json', {'stage':'compile', 'pass':passed, 'source_sha256':inputs, 'seed':a.seed, 'command':json.loads((build/'compile.command.json').read_text()), 'urg_rc':None})
        if not passed:
            print('KSE_NETWORK_COMPILE_FAILED', build)
            return 1
    (out / 'build_path.txt').write_text(str(build) + '\n')
    save(out / 'config.json', dict(vars(a), out=str(out), build=str(build), data=str(data)))
    results = []
    for kind in ['positive'] + (['negative-output'] if a.negative_output else []):
        run = out / kind
        run.mkdir()
        negative = kind != 'positive'
        # A negative run is one sample, selected by --first.  Keeping the
        # default at zero preserves the historical sample0 negative control
        # while allowing the matrix to exercise independent samples.
        first, count = (a.first, 1) if negative else (a.first, a.count)
        cmd = [str(build / 'simv'), '+UVM_TESTNAME=test_kse_network', '+UVM_VERBOSITY=UVM_LOW',
               '+ntb_random_seed=' + str(a.seed), '+DATA=' + str(data), '+FIRST=' + str(first), '+COUNT=' + str(count),
               '+STEP=' + str(a.step), '+STALL_MODE=' + str(a.stall_mode), '+METRICS=' + str(run / 'network_metrics.tsv'),
               '+WATCHDOG_CYCLES=' + str(a.watchdog_cycles),
               '-l', str(run / 'sim.log'), '-cm', CM, '-cm_dir', str(run / 'cov.vdb'), '-cm_name', kind]
        if a.kind == 'soc':
            fw = build / 'firmware/kse_fw.itcm.hex'
            cmd += ['+FW=' + str(fw), '+FW_WORDS=' + str(len(fw.read_text().splitlines()))]
        if a.waves:
            cmd += ['+fsdbfile=' + str(run / 'wave.fsdb')]
        if negative:
            cmd += ['+CORRUPT_OUTPUT_EXPECTED']
        rc = execute(cmd, run, 'sim', a.seconds)
        output = (run / 'sim.console.log').read_bytes()
        if (run / 'sim.log').is_file():
            output += (run / 'sim.log').read_bytes()
        (run / 'check_input.log').write_bytes(output)
        result = check_log(run / 'check_input.log', rc, True,
                           run / 'wave.fsdb' if a.waves else None, 'KSE_NETWORK_COMPLETE')
        text = output.decode(errors='replace')
        accepted = result['verdict'] == 'PASS' and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)', text, re.M)
        if negative:
            golden0 = data / f'sample_{first:02d}_out.hex'
            expected0 = int(golden0.read_text().splitlines()[0], 16)
            corrupted0 = expected0 ^ 1
            pat = (rf'^UVM_ERROR .* \[NETWORK_GOLDEN\] sample={first} word=0 '
                   rf'got={expected0:08x} expected={corrupted0:08x}$')
            matches = [s for s in text.splitlines() if re.fullmatch(pat, s)]
            clean = '\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*', s) else s
                              for s in text.splitlines() if not re.fullmatch(pat, s)) + '\n'
            (run / 'negative-residual.log').write_text(clean)
            residual = check_log(run / 'negative-residual.log', rc, True,
                                 run / 'wave.fsdb' if a.waves else None, 'KSE_NETWORK_COMPLETE')
            save(run / 'negative-residual.json', residual)
            accepted = bool(matches) and result['counts'] == {'UVM_ERROR': 1, 'UVM_FATAL': 0} and residual['verdict'] == 'PASS'
        metrics = re.findall(r'\[NETWORK_SAMPLE\] sample=(\d+).*?window=(\d+) transactions=(\d+)', text)
        save(run / 'verification-record.json', {'source_sha256':inputs, 'seed':a.seed, 'pass':accepted,
            'negative_hit':'NETWORK_GOLDEN' if negative and accepted else None,
            'command':json.loads((run/'sim.command.json').read_text()), 'urg_rc':None,
            'metrics':sorted(set(tuple(map(int,m)) for m in metrics)),
            'reference_cycles':163328, 'reference_transactions':162850})
        save(run / 'result.json', result)
        results.append({'kind': kind, 'accepted': accepted, 'observed_verdict': result['verdict']})
        print(json.dumps(results[-1]), flush=True)
        if not accepted:
            break
    rc = -1
    if results[0]['accepted']:
        rc = execute(['urg', '-full64', '-dir', str(build / 'cov.vdb'), str(out / 'positive/cov.vdb'),
                      '-report', str(out / 'urgReport'), '-format', 'both'], out, 'urg', 240)
    unchanged = all(sha(Path(p)) == h for p, h in inputs.items()) and validate_data(data) == data_hash
    passed = all(t['accepted'] for t in results) and rc == 0 and unchanged and (out / 'urgReport/dashboard.txt').is_file()
    for item in results:
        record=out/item['kind']/'verification-record.json'
        value=json.loads(record.read_text());value['urg_rc']=rc;save(record,value)
    save(out / 'verification-record.json', {'pass':passed,'source_sha256':inputs,'seed':a.seed,'tests':results,'urg_rc':rc,'inputs_unchanged':unchanged})
    save(out / 'summary.json', {'pass': passed, 'tests': results, 'urg_returncode': rc, 'inputs_unchanged': unchanged,
                              'scope': config})
    print('KSE_NETWORK_' + ('DONE' if passed else 'FAILED'), out / 'summary.json')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
