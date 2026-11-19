#!/usr/bin/env python3
"""WP8 KSSOC-008: real E203 SoC peripheral/UART platform test on VCS/UVM.

Builds validation-only firmware (wp8_soc_periph.c + production start.S/link.ld),
compiles the real kse_e203_soc_top (same file list/options as the soc branch of
run_kse_network.py, KSE UVM files replaced by the wp8_soc_periph TB), runs the
positive test and the designated negative control (+WP8_SOC_CORRUPT flips bit 0
of the first expected UART byte), merges positive coverage with urg and checks
that every compiled/control input is unchanged at start and end.

Every vcs/simv/urg invocation holds one shared VCS slot (slot_pool.slot).
Usage: python3 verification/uvm/wp8_kse/wp8_soc_periph_run.py --out NEWDIR [--seed N] [--waves]
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
VCS_TOOLS = REPO / 'tools/verif_tool/vcs'
sys.path.insert(0, str(VCS_TOOLS))
from check_log import check_log  # noqa: E402
from run_kse_bootstrap import execute  # noqa: E402
from slot_pool import slot  # noqa: E402

CM = 'line+cond+fsm+tgl+branch+assert'
TOP = 'tb_wp8_soc_periph'
MARKER = 'WP8_SOC_PERIPH_COMPLETE'
COMPILER = Path(os.environ.get('RISCV_PREFIX', 'riscv-none-elf-') + 'gcc')
NEG_PATTERN = r'^UVM_ERROR .* \[WP8_UART_TX\] byte=0 got=4b expected=4a$'
# Finding F1 reproduction: with +WP8_SOC_STRICT_BOOT_LSR the first LSR read of
# each UART must be the documented reset value 0x60; the design returns 0x61.
F1_PATTERN = r'^UVM_ERROR .* \[WP8_REG\] id=(1|21|26) got=00000061 expected=00000060$'
LICENSE_RE = re.compile(r'SEC-72|\(-15,\d+\)|-15,\d+')


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def save(p, data):
    p.write_text(json.dumps(data, indent=2) + '\n')


def sources_and_controls():
    from kse_resources import memory_config
    pdk, mem = memory_config(REPO)
    macros = ['RAMSP1024X16', 'RAMSP128X16', 'RAMSP4096X16']
    if any(n not in mem['names'] for n in macros):
        raise ValueError('unconfigured SRAM model')
    e = REPO / 'third-party/e203/rtl/e203'
    replaced = {'soc/e203_soc_top.v', 'subsys/e203_subsys_top.v', 'subsys/e203_subsys_main.v',
                'subsys/e203_subsys_mems.v', 'subsys/e203_subsys_plic.v', 'perips/sirv_plic_top.v',
                'perips/apb_uart/apb_uart.v', 'general/sirv_gnrl_ram.v'}
    sources = sorted(p for p in e.rglob('*.v') if str(p.relative_to(e)) not in replaced)
    sources += [REPO / 'rtl/kse' / (n + '.sv') for n in
                ['kse_pkg', 'kse_arith', 'kse_exp_rom', 'kse_gelu_rom', 'kse_post', 'kse_softmax',
                 'kse_ln', 'kse_mac_array', 'kse_rowstore', 'kse_pfifo', 'kse_loader', 'kse_mm', 'kse_pass', 'kse_top']]
    sources += [REPO / 'rtl/kse_soc' / (n + '.sv') for n in
                ['kse_soc_fifo', 'kse_sram_ctrl', 'kse_shared_sram', 'kse_eng_icb', 'kse_accel_sys']]
    sources += [REPO / 'rtl/kse_soc' / (n + '.v') for n in
                ['kse_sirv_plic_top', 'kse_e203_subsys_plic', 'kse_e203_subsys_mems', 'kse_e203_subsys_main',
                 'kse_e203_subsys_top', 'kse_e203_soc_top', 'apb_uart', 'kse_tcm_gnrl_ram']]
    sources += [Path(mem['v'].format(name=n)) for n in macros]
    sources += [HERE / n for n in ['wp8_soc_periph_if.sv', 'wp8_soc_periph_pkg.sv', TOP + '.sv']]
    incdirs = [e / n for n in ['core', 'perips', 'perips/apb_i2c']]
    controls = [pdk, Path(__file__).resolve(), VCS_TOOLS / 'check_log.py', VCS_TOOLS / 'run_kse_bootstrap.py',
                VCS_TOOLS / 'slot_pool.py', HERE / 'wp8_soc_periph.c', REPO / 'firmware/kse/start.S',
                REPO / 'firmware/kse/link.ld', REPO / 'tools/kse_soc/bin2itcm.py', COMPILER]
    controls += sorted((e / 'core').glob('*.v')) + sorted((e / 'perips/apb_i2c').glob('*.v'))
    for p in sources + controls:
        if not p.is_file():
            raise FileNotFoundError(p)
    return sources, incdirs, controls, mem


def vcs_step(argv, cwd, name, seconds, state, attempts=3):
    """Run one licensed VCS-family command under a shared slot; retry license failures."""
    rc = None
    for attempt in range(attempts):
        with slot(state):
            rc = execute(argv, cwd, name, seconds)
        text = (cwd / (name + '.console.log')).read_text(errors='replace')
        if rc == 0 or not LICENSE_RE.search(text):
            return rc
        (cwd / f'{name}.license-attempt{attempt}.log').write_text(text)
        time.sleep(60)
    return rc


def build_firmware(out):
    fw = out / 'firmware'
    fw.mkdir()
    prefix = str(COMPILER)[:-3]
    elf = fw / 'wp8_soc_periph.elf'
    cmds = [[str(COMPILER), '-march=rv32imac_zicsr', '-mabi=ilp32', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
             '-std=c11', '-ffreestanding', '-fno-builtin', '-fno-common', '-msmall-data-limit=0', '-mno-relax',
             '-nostdlib', '-nostartfiles', '-static',
             '-Wl,-T,' + str(REPO / 'firmware/kse/link.ld') + ',--no-relax,--build-id=none,-Map,' + str(fw / 'wp8_soc_periph.map'),
             str(REPO / 'firmware/kse/start.S'), str(HERE / 'wp8_soc_periph.c'), '-o', str(elf)],
            [prefix + 'objcopy', '-O', 'binary', str(elf), str(fw / 'wp8_soc_periph.bin')],
            ['python3', str(REPO / 'tools/kse_soc/bin2itcm.py'), str(fw / 'wp8_soc_periph.bin'),
             str(fw / 'wp8_soc_periph.itcm.hex')]]
    for i, cmd in enumerate(cmds):
        if execute(cmd, fw, 'firmware-' + str(i), 180):
            raise RuntimeError('firmware build failed, see ' + str(fw))
    with (fw / 'wp8_soc_periph.lst').open('w') as f:
        subprocess.run([prefix + 'objdump', '-d', '-S', str(elf)], stdout=f, check=True)
    execute([str(COMPILER), '--version'], fw, 'compiler-version', 20)
    return fw / 'wp8_soc_periph.itcm.hex', {str(p): sha(p) for p in sorted(fw.iterdir()) if p.is_file()}


def parse_metrics(text):
    m = {'apb': {}, 'icb': {}}
    for g in re.finditer(r'\[WP8_BUSCOUNT\] apb port=(\w+) base=(\w+) writes=(\d+) reads=(\d+) apb_access=(\d+) '
                         r'icb_cmd=(\d+) icb_rsp=(\d+)', text):
        m['apb'][g[1]] = {'base': g[2], 'writes': int(g[3]), 'reads': int(g[4]), 'apb_access': int(g[5]),
                          'icb_cmd': int(g[6]), 'icb_rsp': int(g[7])}
    for g in re.finditer(r'\[WP8_BUSCOUNT\] icb port=(\w+) base=(\w+) writes=(\d+) reads=(\d+) zero_latency_rsp=(\d+)', text):
        m['icb'][g[1]] = {'base': g[2], 'writes': int(g[3]), 'reads': int(g[4]), 'zero_latency_rsp': int(g[5])}
    g = re.search(r'\[WP8_SUMMARY\] uart_tx frames=(\d+) decoded=(\d+) expected=(\d+) framing_bad=(\d+) thr_writes=(\d+)', text)
    if g:
        m['uart_tx'] = dict(zip(['frames', 'decoded', 'expected', 'framing_bad', 'thr_writes'], map(int, g.groups())))
    g = re.search(r'\[WP8_SUMMARY\] uart_rx driven=(\d+) rbr_reads=(\d+)', text)
    if g:
        m['uart_rx'] = {'driven': int(g[1]), 'rbr_reads': int(g[2])}
    g = re.search(r'\[WP8_SUMMARY\] cpu status=(\w+) records=(\d+) mailbox_writes=(\d+)', text)
    if g:
        m['cpu'] = {'status': g[1], 'records': int(g[2]), 'mailbox_writes': int(g[3])}
    return m


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', type=Path, required=True, help='new output directory (must not exist)')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--waves', action='store_true')
    ap.add_argument('--no-negative', action='store_true')
    ap.add_argument('--no-urg', action='store_true')
    ap.add_argument('--seconds', type=int, default=1800)
    a = ap.parse_args(argv)
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    state = out / 'slot_state.json'
    sources, incdirs, controls, mem = sources_and_controls()
    inputs = {str(p): sha(p) for p in sources + controls}
    git = subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    rel = [os.path.relpath(p, REPO) for p in inputs if str(p).startswith(str(REPO) + '/')]
    dirty = subprocess.run(['git', '-C', str(REPO), 'status', '--porcelain', '--'] + rel,
                           capture_output=True, text=True).stdout.splitlines()
    print('WP8_SOC_PERIPH_OUT=' + str(out), flush=True)
    fw_hex, fw_hashes = build_firmware(out)
    config = {'files': inputs, 'top': TOP, 'repo': str(REPO), 'git_head': git, 'git_dirty_inputs': dirty,
              'firmware_artifacts': fw_hashes,
              'parameters': 'production defaults; UART0 divisor 15 (16 hfclk/bit) set by firmware',
              'initialization': 'strict four-state, no initreg; ITCM loaded only during pad reset; loader port idle',
              'started_at': datetime.datetime.now().astimezone().isoformat()}
    build = out / 'build'
    build.mkdir()
    save(build / 'source_manifest.json', config)
    (build / 'files.f').write_text('\n'.join(['+incdir+' + str(p) for p in incdirs] + [str(p) for p in sources]) + '\n')
    (build / 'coverage.hier').write_text('+tree ' + TOP + '\n')
    cmd = ['vcs', '-full64', '-sverilog', '-ntb_opts', 'uvm-1.2', '-timescale=1ns/1ps',
           '-kdb', '-debug_access+all', '-assert', 'svaext', '-lca', '-top', TOP,
           '-f', str(build / 'files.f'), '-Mdir=' + str(build / 'csrc'), '-o', str(build / 'simv'),
           '-l', str(build / 'compile.log'), '-cm', CM, '-cm_dir', str(build / 'cov.vdb'),
           '-cm_hier', str(build / 'coverage.hier')]
    cmd += ['+define+' + n for n in mem['sim_defines']] + mem.get('sim_opts', [])
    rc = vcs_step(cmd, build, 'compile', 1500, state)
    text = (build / 'compile.console.log').read_text(errors='replace')
    warnings = re.findall(r'Warning-\[([^]]+)\]', text)
    compiled = (rc == 0 and (build / 'simv').is_file() and all(n == 'LCA_FEATURES_ENABLED' for n in warnings)
                and not re.search(r'Error-|Fatal-|^Warning\s*:', text, re.M))
    save(build / 'compile_result.json', {'pass': compiled, 'returncode': rc, 'warnings': warnings})
    if not compiled:
        print('WP8_SOC_PERIPH_COMPILE_FAILED', build)
        save(out / 'summary.json', {'pass': False, 'stage': 'compile', 'returncode': rc, 'warnings': warnings})
        return 1
    results = []
    kinds = ['positive'] + ([] if a.no_negative else ['negative-uart', 'repro-f1-boot-lsr'])
    for kind in kinds:
        run = out / kind
        run.mkdir()
        negative = kind == 'negative-uart'
        repro = kind.startswith('repro')
        cmd = [str(build / 'simv'), '+UVM_TESTNAME=test_wp8_soc_periph', '+UVM_VERBOSITY=UVM_LOW',
               '+ntb_random_seed=' + str(a.seed), '+FW=' + str(fw_hex),
               '+FW_WORDS=' + str(len(fw_hex.read_text().splitlines())), '-l', str(run / 'sim.log'),
               '-cm', CM, '-cm_dir', str(run / 'cov.vdb'), '-cm_name', kind.replace('-', '_')]
        if a.waves:
            cmd += ['+fsdbfile=' + str(run / 'wave.fsdb')]
        if negative:
            cmd += ['+WP8_SOC_CORRUPT']
        if repro:
            cmd += ['+WP8_SOC_STRICT_BOOT_LSR']
        rc = vcs_step(cmd, run, 'sim', a.seconds, state)
        output = (run / 'sim.console.log').read_bytes()
        if (run / 'sim.log').is_file():
            output += (run / 'sim.log').read_bytes()
        (run / 'check_input.log').write_bytes(output)
        fsdb = run / 'wave.fsdb' if a.waves else None
        result = check_log(run / 'check_input.log', rc, True, fsdb, MARKER)
        save(run / 'result.json', result)
        text = output.decode(errors='replace')
        metrics = parse_metrics((run / 'sim.log').read_text(errors='replace') if (run / 'sim.log').is_file() else text)
        save(run / 'metrics.json', metrics)
        no_warn = not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)', text, re.M)
        if negative:
            matches = [s for s in text.splitlines() if re.fullmatch(NEG_PATTERN, s)]
            clean = '\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*', s) else s
                              for s in text.splitlines() if not re.fullmatch(NEG_PATTERN, s)) + '\n'
            (run / 'negative-residual.log').write_text(clean)
            residual = check_log(run / 'negative-residual.log', rc, True, fsdb, MARKER)
            save(run / 'negative-residual.json', residual)
            accepted = (bool(matches) and result['verdict'] == 'FAIL' and
                        result['counts'] == {'UVM_ERROR': 1, 'UVM_FATAL': 0} and residual['verdict'] == 'PASS' and no_warn)
        elif repro:
            # console + -l log repeat each message; count distinct designated ids
            ids = sorted({re.fullmatch(F1_PATTERN, s)[1] for s in text.splitlines() if re.fullmatch(F1_PATTERN, s)})
            clean = '\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*3\s*', s) else s
                              for s in text.splitlines() if not re.fullmatch(F1_PATTERN, s)) + '\n'
            (run / 'repro-residual.log').write_text(clean)
            residual = check_log(run / 'repro-residual.log', rc, True, fsdb, MARKER)
            save(run / 'repro-residual.json', residual)
            accepted = (ids == ['1', '21', '26'] and result['counts'] == {'UVM_ERROR': 3, 'UVM_FATAL': 0}
                        and residual['verdict'] == 'PASS' and no_warn)
        else:
            accepted = result['verdict'] == 'PASS' and no_warn and 'TEST PASSED' in text
        results.append({'kind': kind, 'accepted': accepted, 'observed_verdict': result['verdict'],
                        'counts': result['counts'], 'first_error': result['first_error']})
        print(json.dumps(results[-1]), flush=True)
    urg_rc = None
    if results and results[0]['accepted'] and not a.no_urg:
        urg_rc = vcs_step(['urg', '-full64', '-dir', str(build / 'cov.vdb'), str(out / 'positive/cov.vdb'),
                           '-report', str(out / 'urgReport'), '-format', 'both'], out, 'urg', 600, state)
    changed = [p for p, h in inputs.items() if not Path(p).is_file() or sha(p) != h]
    fw_changed = [p for p, h in fw_hashes.items() if sha(p) != h]
    unchanged = not changed and not fw_changed
    urg_ok = a.no_urg or (urg_rc == 0 and (out / 'urgReport/dashboard.txt').is_file())
    passed = bool(results) and all(r['accepted'] for r in results) and unchanged and urg_ok
    save(out / 'summary.json', {'pass': passed, 'tests': results, 'urg_returncode': urg_rc,
                                'inputs_checked': len(inputs), 'inputs_unchanged': unchanged,
                                'changed_inputs': changed + fw_changed, 'git_head': git,
                                'git_dirty_inputs_at_start': dirty,
                                'finished_at': datetime.datetime.now().astimezone().isoformat(),
                                'scope': 'KSSOC-008: real E203 firmware drives UART0 (modified apb_uart_sv) TX/RX '
                                         'through GPIOA IOF pads and register-checks every instantiated peripheral'})
    print('WP8_SOC_PERIPH_' + ('DONE' if passed else 'FAILED'), out / 'summary.json')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
