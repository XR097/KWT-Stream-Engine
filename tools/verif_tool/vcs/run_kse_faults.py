#!/usr/bin/env python3
"""Strict-final real engine + single-port SRAM/bus fault/reset UVM, sample0."""
import argparse
import json
import os
from pathlib import Path
import re

import yaml
from check_log import check_log
from run_kse_bootstrap import execute
from run_kse_network import REPO, CM, sha, save, validate_data


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--data', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--build', type=Path)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--waves', action='store_true')
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--control-only', action='store_true')
    ap.add_argument('--negative-target', choices=['FAULT_MMIO','FAULT_PROGRESS','FAULT_FABRIC','FAULT_SRAM_DATA','FAULT_PUBLICATION','FAULT_IRQ','FAULT_QUEUE','FAULT_DMA_DATA','FAULT_RELEASE','RESET_COUNTS','FAULT_PRIORITY','FAULT_DRAIN','RECOVERY_GOLDEN'])
    ap.add_argument('--seconds', type=int, default=1800)
    a = ap.parse_args()
    data, out = a.data.resolve(), a.out.resolve()
    data_hash = validate_data(data)
    out.mkdir(parents=True, exist_ok=False)
    from kse_resources import memory_config
    pdk, mem = memory_config(REPO)
    names = ['kse_pkg','kse_arith','kse_exp_rom','kse_gelu_rom','kse_post','kse_softmax','kse_ln',
             'kse_mac_array','kse_rowstore','kse_pfifo','kse_loader','kse_mm','kse_pass','kse_top']
    sources = [REPO / 'rtl/kse' / (n + '.sv') for n in names]
    sources += [REPO / 'rtl/kse_soc' / (n + '.sv') for n in ['kse_soc_fifo','kse_sram_ctrl','kse_shared_sram','kse_sys_bus','kse_eng_icb']]
    macros = ['RAMSP1024X16','RAMSP128X16','RAMSP4096X16']
    from kse_resources import e203_sources
    e = e203_sources()
    sources += [e / 'general' / n for n in ['sirv_gnrl_icbs.v','sirv_gnrl_dffs.v','sirv_gnrl_bufs.v','sirv_gnrl_xchecker.v']]
    if any(n not in mem['names'] for n in macros):
        raise ValueError('SRAM model absent from public PDK config')
    sources += [Path(mem['v'].format(name=n)) for n in macros]
    sources += [REPO / 'verification/uvm/kse' / n for n in
                ['kse_fault_if.sv','kse_fault_pkg.sv','tb_kse_fault_uvm.sv']]
    controls = [pdk, Path(__file__).resolve()] + [Path(__file__).with_name(n) for n in
                ['check_log.py','run_kse_bootstrap.py','run_kse_network.py','kse_resources.py']]
    inputs = {str(p): sha(p) for p in sources + controls}
    config = {'files':inputs,'top':'tb_kse_fault_uvm','data_manifest_sha256':data_hash,
              'parameters':'kse_eng_icb production defaults R32 C32 PF128 SM8 LN8 REL_LAG0; real single-port SRAM and DMA>loader>CPU arbiter; CPU idle; ordered DMA latency/error interposer',
              'initialization':'strict four state; no initreg; core SRAM retained through reset',
              'reset_contract':'engine, bus, SRAM control and interposer cancel together; SRAM content retained; no old late response injected; loader progress exclusively via ICB doorbells'}
    build = a.build.resolve() if a.build else out / 'build'
    if a.build:
        if json.loads((build / 'source_manifest.json').read_text()) != config:
            raise ValueError('build sources/configuration changed')
        if not json.loads((build / 'compile_result.json').read_text())['pass']:
            raise ValueError('build not accepted')
    else:
        build.mkdir()
        save(build / 'source_manifest.json', config)
        (build / 'files.f').write_text('\n'.join(str(p) for p in sources) + '\n')
        (build / 'coverage.hier').write_text('+tree tb_kse_fault_uvm\n')
        cmd = ['vcs','-full64','-sverilog','-ntb_opts','uvm-1.2','-timescale=1ns/1ps',
               '-kdb','-debug_access+all','-assert','svaext','-lca','-top','tb_kse_fault_uvm',
               '-f',str(build / 'files.f'),'-Mdir='+str(build / 'csrc'),'-o',str(build / 'simv'),
               '-l',str(build / 'compile.log'),'-cm',CM,'-cm_dir',str(build / 'cov.vdb'),
               '-cm_hier',str(build / 'coverage.hier')]
        cmd += ['+define+' + n for n in mem['sim_defines']] + mem.get('sim_opts', [])
        rc = execute(cmd, build, 'compile', 1200)
        text = (build / 'compile.console.log').read_text(errors='replace')
        warnings = re.findall(r'Warning-\[([^]]+)\]', text)
        passed = rc == 0 and (build / 'simv').is_file() and all(n == 'LCA_FEATURES_ENABLED' for n in warnings)
        passed = passed and not re.search(r'Error-|Fatal-|^Warning\s*:', text, re.M)
        save(build / 'compile_result.json', {'pass':passed,'returncode':rc,'warnings':warnings})
        save(out/'verification-record.json', {'stage':'compile','pass':passed,'source_sha256':inputs,'seed':a.seed,'command':json.loads((build/'compile.command.json').read_text()),'urg_rc':None})
        if not passed:
            print('KSE_FAULT_COMPILE_FAILED', build)
            return 1
    (out / 'build_path.txt').write_text(str(build) + '\n')
    save(out / 'config.json', dict(vars(a), data=str(data), out=str(out), build=str(build)))
    results=[]
    negatives = ([a.negative_target] if a.negative_target else
                 (['FAULT_MMIO'] if a.control_only else ['FAULT_MMIO', 'FAULT_PROGRESS', 'FAULT_FABRIC', 'FAULT_SRAM_DATA',
                 'FAULT_PUBLICATION', 'FAULT_IRQ', 'FAULT_QUEUE', 'FAULT_DMA_DATA',
                 'FAULT_RELEASE', 'RESET_COUNTS', 'FAULT_PRIORITY', 'FAULT_DRAIN', 'RECOVERY_GOLDEN']))
    for kind in ['positive'] + (['negative-' + n for n in negatives] if a.negative else []):
        negative = kind != 'positive'
        run=out / kind
        run.mkdir()
        cmd=[str(build / 'simv'),'+UVM_TESTNAME=test_kse_faults','+UVM_VERBOSITY=UVM_LOW',
             '+ntb_random_seed='+str(a.seed),'+DATA='+str(data),'-l',str(run/'sim.log'),
             '-cm',CM,'-cm_dir',str(run/'cov.vdb'),'-cm_name',kind]
        if a.waves:
            cmd += ['+fsdbfile='+str(run/'wave.fsdb')]
        target = kind.removeprefix('negative-') if negative else None
        if negative:
            cmd += ['+NEGATIVE=' + target]
            if target == 'FAULT_MMIO':
                cmd += ['+CORRUPT_FAULT_EXPECTED']
            if target == 'FAULT_PUBLICATION':
                cmd += ['+PUB_ONLY']
            if target in ('FAULT_PROGRESS','FAULT_FABRIC','FAULT_SRAM_DATA'):
                cmd += ['+BUS_ONLY']
            if target == 'FAULT_SRAM_DATA':
                cmd = [x for x in cmd if x != '+BUS_ONLY']
                cmd += ['+SRAM_ONLY']
            if target == 'RESET_COUNTS':
                cmd += ['+RESET_ONLY', '+SHORT_CONTROL']
            else:
                cmd += ['+RECOVERY_ONLY'] if target in ('FAULT_PRIORITY', 'FAULT_DRAIN', 'RECOVERY_GOLDEN') else ['+SHORT_CONTROL']
        elif a.control_only:
            cmd += ['+SHORT_CONTROL']
        rc=execute(cmd,run,'sim',a.seconds)
        output=(run/'sim.console.log').read_bytes()
        if (run/'sim.log').exists():
            output += (run/'sim.log').read_bytes()
        (run/'check_input.log').write_bytes(output)
        result=check_log(run/'check_input.log',rc,True,run/'wave.fsdb' if a.waves else None,'KSE_FAULT_COMPLETE')
        text=output.decode(errors='replace')
        accepted=result['verdict']=='PASS' and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)',text,re.M)
        if not negative and not a.control_only:
            features={int(i):int(n) for i,n in re.findall(r'^UVM_INFO .* \[FAULT_FEATURE\] feature=(\d+) hits=(\d+)$',text,re.M)}
            accepted=accepted and set(features)==set(range(21)) and all(n>0 for n in features.values())
            accepted=accepted and bool(re.search(r'\[RECOVERY_COMPLETE\] reads=80592 input=1584 params=79008 writes=1584 ack=1584 commands=12 core=12 events=12 final_bytes=6336 epoch=\d+',text))
        if negative:
            pattern=r'^UVM_ERROR .* \[' + re.escape(target) + r'\] .*$'
            hits=re.findall(pattern,text,re.M)
            clean='\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*',s) else s
                            for s in text.splitlines() if not re.fullmatch(pattern,s))+'\n'
            (run/'negative-residual.log').write_text(clean)
            residual=check_log(run/'negative-residual.log',rc,True,run/'wave.fsdb' if a.waves else None,'KSE_FAULT_COMPLETE')
            save(run/'negative-residual.json',residual)
            accepted=bool(hits) and result['verdict']=='FAIL' and result['counts']=={'UVM_ERROR':1,'UVM_FATAL':0} and residual['verdict']=='PASS'
        save(run/'result.json',result)
        save(run/'verification-record.json', {'kind':kind,'seed':a.seed,'target':target,
             'source_sha256':inputs,'data_manifest_sha256':data_hash,'command':json.loads((run/'sim.command.json').read_text()),
             'pass':bool(accepted),'observed_verdict':result['verdict'],'counts':result['counts'],
             'negative_residual':json.loads((run/'negative-residual.json').read_text()) if (run/'negative-residual.json').is_file() else None})
        results.append({'kind':kind,'accepted':bool(accepted),'observed_verdict':result['verdict'], 'target':target,
                        'counts':result['counts'],
                        'diagnostics':re.findall(r'^UVM_ERROR .* \[([^]]+)\]', text, re.M),
                        'features':dict(re.findall(r'\[FAULT_FEATURE\] feature=(\d+) hits=(\d+)', text)),
                        'recovery':re.findall(r'\[RECOVERY_COMPLETE\] (.*)', text)[:1],
                        'bus_counts':re.findall(r'\[FAULT_BUS_COUNTS\] (.*)', text)[:1]})
        print(json.dumps(results[-1]),flush=True)
        if not accepted:
            break
    rc=-1
    if results[0]['accepted']:
        rc=execute(['urg','-full64','-dir',str(build/'cov.vdb'),str(out/'positive/cov.vdb'),
                    '-report',str(out/'urgReport'),'-format','both'],out,'urg',240)
    unchanged=all(sha(Path(p))==h for p,h in inputs.items()) and validate_data(data)==data_hash
    passed=all(t['accepted'] for t in results) and rc==0 and unchanged and (out/'urgReport/dashboard.txt').is_file()
    record = {'pass':passed,'tests':results,'urg_returncode':rc,'inputs_unchanged':unchanged,
                             'full_matrix':not a.control_only,'scope':config,
              'seed':a.seed, 'data_manifest_sha256':data_hash,
              'commands':[json.loads(p.read_text()) for p in sorted(out.rglob('*.command.json'))],
              'coverage_dashboard':(out/'urgReport/dashboard.txt').read_text() if (out/'urgReport/dashboard.txt').is_file() else None,
              'limitations':['sample0 only; no E203/PLIC execution', 'fault injection is the DMA response boundary, not a physical SRAM fault',
                             'BASE restart only when DMA drained; undefined late responses not injected',
                             'one complete recovery after matrix, not after each abort; no intermediate arithmetic checkpoints']}
    save(out/'summary.json',record)
    save(out/'verification-record.json',record)
    print('KSE_FAULT_'+('DONE' if passed else 'FAILED'),out/'summary.json')
    return 0 if passed else 1


if __name__=='__main__':
    raise SystemExit(main())
