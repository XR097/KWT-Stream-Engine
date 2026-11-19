#!/usr/bin/env python3
"""Independent strict-final shared SRAM/system bus matrix, sequential shared VCS slots."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time

import yaml

REPO = Path(__file__).resolve().parents[3]
SLOT = Path(os.environ.get('VCS_SLOT_WRAPPER', 'vcs'))
E203_SHA = '5895d5bfba688ac48ea6fe011c27ba983b6f6445'
CHECKERS = ['SINGLE_PORT', 'CMD_HOLD', 'RSP_HOLD', 'ORDER', 'DATA', 'PRIORITY',
            'CONSERVATION', 'LATENCY', 'RESET', 'DOORBELL', 'GROUP_MAP', 'THROUGHPUT', 'COVERAGE']
CM = 'line+cond+tgl+fsm+branch+assert'


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def save(p, value):
    p.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def execute(argv, cwd, name, heavy=False, seconds=1800):
    actual = [str(SLOT), 'bash', '-lc', shlex.join(argv)] if heavy else ['bash', '-lc', shlex.join(argv)]
    meta = dict(argv=argv, actual_argv=actual, cwd=str(cwd), started_at=dt.datetime.now().astimezone().isoformat())
    save(cwd / (name + '-command.json'), meta)
    start = time.monotonic()
    with (cwd / (name + '.console.log')).open('w') as f:
        proc = subprocess.Popen(actual, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = proc.wait(seconds)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            rc = 124
    meta.update(returncode=rc, elapsed_seconds=round(time.monotonic()-start, 3))
    save(cwd / (name + '-command.json'), meta)
    return rc


def diagnostic_lines(text):
    return re.findall(r'^UVM_(?:ERROR|FATAL) (?!\s*:).*$', text, re.M)


def result(text, rc, negative):
    diags = diagnostic_lines(text)
    counts = {s: int(re.search(r'^UVM_' + s + r'\s*:\s*(\d+)\s*$', text, re.M).group(1))
              if re.search(r'^UVM_' + s + r'\s*:\s*(\d+)\s*$', text, re.M) else None
              for s in ['ERROR', 'FATAL']}
    tool_bad = re.findall(r'^.*(?:Error-\[|Fatal-\[|^Error:|^Fatal:|^\s*Error:|^\s*Fatal:|\$error|\$fatal|Assertion.*failed|STRICT_BUS_WATCHDOG).*$', text, re.M)
    complete = 'STRICT_BUS_COMPLETE' in text
    clean = rc == 0 and complete and not tool_bad and counts['FATAL'] == 0
    if negative:
        only_target = len(diags) == 1 and ('[' + negative + ']') in diags[0]
        injects = re.findall(r'\[NEG_INJECT\].*checker=(\w+)', text)
        accepted = clean and counts['ERROR'] == 1 and only_target and injects == [negative] and 'TEST FAILED' in text and 'TEST PASSED' not in text
    else:
        accepted = clean and counts['ERROR'] == 0 and not diags and 'TEST PASSED' in text and 'TEST FAILED' not in text
    ports = [dict(zip(['port', 'req', 'rsp', 'cancelled', 'max_wait', 'random_max_wait'], map(int, m)))
             for m in re.findall(r'\[COUNTS\] port=(\d+) req=(\d+) rsp=(\d+) cancelled=(\d+) max_wait=(\d+) random_max_wait=(\d+)', text)]
    metrics = re.search(r'\[METRICS\] (.*)', text)
    return dict(accepted=bool(accepted), raw_verdict='FAIL' if negative or not accepted else 'PASS',
                expected_checker=negative or None, diagnostics=diags, counts=counts, complete=complete,
                residual_pass=bool(accepted) if negative else None, returncode=rc,
                tool_errors=tool_bad, ports=ports, metrics=metrics.group(1) if metrics else None)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=REPO / 'run/strict-final' / ('strict-bus-' + dt.datetime.now().strftime('%Y%m%d-%H%M%S')))
    ap.add_argument('--e203', type=Path, default=REPO / 'third-party/e203')
    ap.add_argument('--seeds', type=int, nargs='+', default=[1, 7, 42])
    ap.add_argument('--models', nargs='+', choices=['behavior', 'pdk_macro'], default=['behavior', 'pdk_macro'])
    ap.add_argument('--no-negative', action='store_true')
    ap.add_argument('--quick', action='store_true', help='diagnostic only; not full-address acceptance')
    args = ap.parse_args()
    out=args.out.resolve()
    if not out.is_relative_to(REPO / 'run/strict-final'):
        ap.error('--out must be inside this workspace run/strict-final')
    out.mkdir(parents=True, exist_ok=False)
    e203=args.e203.resolve()
    generals=e203 / 'rtl/e203/general'
    from kse_resources import memory_config
    pdk, mem = memory_config(REPO)
    assert 'RAMSP4096X16' in mem['names']
    common=[generals / (n+'.v') for n in ['sirv_gnrl_dffs','sirv_gnrl_bufs','sirv_gnrl_icbs','sirv_gnrl_xchecker']]
    common += [REPO / 'rtl/kse_soc' / (n+'.sv') for n in ['kse_sram_ctrl','kse_shared_sram','kse_sys_bus']]
    dv=REPO / 'verification/uvm/kse'
    tb=[dv/'strict_bus/strict_bus_if.sv',dv/'strict_bus/strict_bus_pkg.sv',dv/'tb_kse_strict_bus_uvm.sv']
    include_files=list((e203/'rtl/e203').rglob('*.vh'))
    all_results=[]
    records=[]
    for model in args.models:
        root=out/model;build=root/'build';build.mkdir(parents=True)
        macro=REPO/'tb/kse_soc/RAMSP4096X16_beh.sv' if model=='behavior' else Path(mem['v'].format(name='RAMSP4096X16'))
        sources=common+[macro]+tb
        inputs={str(p):sha(p) for p in sources+include_files+[Path(__file__).resolve(),pdk,SLOT]}
        record=dict(model=model, e203_pinned_gitlink=E203_SHA, files_sha256=inputs, seeds=args.seeds,
                    quick=args.quick, scope='kse_sys_bus DMA>loader>CPU plus single kse_shared_sram; no engine/SoC; four-state; initialized by ICB; no initreg',
                    tests=[], compile=None, urg_returncode=None)
        records.append(record)
        save(root/'verification-record.json',record)
        (build/'files.f').write_text('\n'.join(map(str,sources))+'\n')
        (build/'coverage.hier').write_text('+tree tb_kse_strict_bus_uvm\n')
        cmd=['vcs','-full64','-sverilog','-ntb_opts','uvm-1.2','-timescale=1ns/1ps','-assert','svaext',
             '-top','tb_kse_strict_bus_uvm','+incdir+'+str(generals),'+incdir+'+str(e203/'rtl/e203/core'),
             '-f',str(build/'files.f'),'-o',str(build/'simv'),'-Mdir='+str(build/'csrc'),
             '-cm',CM,'-cm_dir',str(build/'cov.vdb'),'-cm_hier',str(build/'coverage.hier'),'-l',str(build/'compile.log')]
        if model=='pdk_macro':cmd+=['+define+'+d for d in mem['sim_defines']]+mem.get('sim_opts',[])
        rc=execute(cmd,build,'compile',True)
        log=(build/'compile.console.log').read_text(errors='replace')
        compile_pass=rc==0 and (build/'simv').is_file() and not re.search(r'Error-\[|Fatal-\[',log)
        record['compile']=dict(returncode=rc,accepted=compile_pass,warnings=re.findall(r'Warning-\[([^]]+)\]',log))
        save(root/'verification-record.json',record)
        print(model,'COMPILE_DONE' if compile_pass else 'COMPILE_FAILED',root,flush=True)
        if not compile_pass:continue
        cases=[('positive',s,None) for s in args.seeds]
        if not args.no_negative:cases += [('negative-'+c,args.seeds[0],c) for c in CHECKERS]
        positives=[]
        for kind,seed,negative in cases:
            run=root/(kind+'-s'+str(seed));run.mkdir()
            cmd=[str(build/'simv'),'+ntb_random_seed='+str(seed),'+UVM_VERBOSITY=UVM_LOW',
                 '-cm',CM,'-cm_dir',str(run/'cov.vdb'),'-cm_name',kind+'-s'+str(seed),'-l',str(run/'sim.log')]
            if args.quick or negative:cmd+=['+QUICK']
            if negative:cmd+=['+NEG='+negative]
            if model=='pdk_macro':cmd+=mem.get('sim_opts',[])
            rc=execute(cmd,run,'sim',True)
            log=(run/'sim.console.log').read_text(errors='replace')
            t=result(log,rc,negative)
            t.update(name=kind,seed=seed,command=cmd,files_sha256=inputs)
            save(run/'verification-record.json',t)
            record['tests'].append(t);all_results.append(t)
            if negative and t['accepted']:
                residual='\n'.join(line for line in log.splitlines() if line not in t['diagnostics'])
                residual=re.sub(r'(^UVM_ERROR\s*:)\s*1\s*$',r'\1 0',residual,flags=re.M).replace('TEST FAILED','TEST PASSED')
                (run/'negative-residual.log').write_text(residual+'\n')
            elif not negative and t['accepted']:positives.append(run/'cov.vdb')
            save(root/'verification-record.json',record)
            print(model,kind,seed,'ACCEPTED' if t['accepted'] else 'REJECTED',flush=True)
        if positives:
            rc=execute(['urg','-full64','-dir',str(build/'cov.vdb')]+list(map(str,positives))+
                       ['-report',str(root/'urgReport'),'-format','both'],root,'urg',seconds=300)
            record['urg_returncode']=rc
            dashboard=root/'urgReport/dashboard.txt'
            record['coverage_dashboard']=dashboard.read_text() if dashboard.exists() else None
        record['inputs_unchanged']=all(sha(Path(p))==h for p,h in inputs.items())
        record['pass']=compile_pass and all(t['accepted'] for t in record['tests']) and record['urg_returncode']==0 and bool(record.get('coverage_dashboard')) and record['inputs_unchanged']
        save(root/'verification-record.json',record)
    passed=bool(all_results) and all(r.get('pass',False) for r in records)
    save(out/'verification-record.json',dict(pass_matrix=passed,models=records,full_matrix=not args.quick and len(set(args.seeds))>=3 and set(args.models)=={'behavior','pdk_macro'} and not args.no_negative))
    print('STRICT_BUS_MATRIX_'+('PASS' if passed else 'FAIL'),out,flush=True)
    return 0 if passed else 1


if __name__=='__main__':
    raise SystemExit(main())
