#!/usr/bin/env python3
"""VCS/UVM kse_top frozen-golden stream regression, strict four-state.

Use prepare_kse_stream.py once with NumPy, then provide its immutable --data.
Every invocation uses a new --out; explicit --build reuse verifies input hashes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys

import yaml

from check_log import check_log
from run_kse_bootstrap import execute as raw_execute

REPO=Path(__file__).resolve().parents[3]
CM='line+cond+fsm+tgl+branch+assert'


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')


def validate_data(path):
    m=json.loads((path/'data_manifest.json').read_text())
    if m['candidate']!='e3521354cc15f0877aef_middle' or m['samples']!=24 or m['layers']!=12:raise ValueError('wrong data identity')
    for group in ('inputs','outputs'):
        for name,spec in m[group].items():
            p=Path(name)
            if not p.is_file() or p.stat().st_size!=spec['bytes'] or sha(p)!=spec['sha256']:raise ValueError('data changed: '+name)
    return sha(path/'data_manifest.json')



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


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True);ap.add_argument('--data',type=Path,required=True)
    ap.add_argument('--build',type=Path);ap.add_argument('--compile-only',action='store_true')
    ap.add_argument('--first',type=int,default=0);ap.add_argument('--count',type=int,default=24)
    ap.add_argument('--layers',type=int,default=12);ap.add_argument('--outall',type=int,choices=[0,1],default=1)
    ap.add_argument('--mode',type=int,choices=[0,1,2],default=0);ap.add_argument('--seed',type=int,default=1)
    ap.add_argument('--waves',action='store_true');ap.add_argument('--negative',action='store_true')
    ap.add_argument('--seconds',type=int,default=3600)
    a=ap.parse_args()
    if a.first<0 or a.count<1 or a.first+a.count>24 or not 1<=a.layers<=12:ap.error('invalid sample/layer range')
    out=a.out.resolve();data=a.data.resolve();data_hash=validate_data(data)
    out.mkdir(parents=True,exist_ok=False)
    from kse_resources import memory_config
    pdk, mem = memory_config(REPO)
    macros=['RAMSP1024X16','RAMSP128X16']
    if any(n not in mem['names'] for n in macros):raise ValueError('PDK macro not configured')
    sources=[REPO/'rtl/kse'/(n+'.sv') for n in ['kse_pkg','kse_arith','kse_exp_rom','kse_gelu_rom','kse_post','kse_softmax','kse_ln','kse_mac_array','kse_rowstore','kse_pfifo','kse_loader','kse_mm','kse_pass','kse_top']]
    sources += [Path(mem['v'].format(name=n)) for n in macros]
    sources += [REPO/'verification/uvm/kse'/n for n in ['kse_stream_if.sv','kse_stream_pkg.sv','tb_kse_stream.sv']]
    controls=[pdk,Path(__file__).resolve(),Path(__file__).with_name('prepare_kse_stream.py'),Path(__file__).with_name('check_log.py'),Path(__file__).with_name('run_kse_bootstrap.py')]
    inputs={str(p):sha(p) for p in sources+controls}
    build=a.build.resolve() if a.build else out/'build'
    if a.build:
        m=json.loads((build/'source_manifest.json').read_text())
        if m['files']!=inputs or not (build/'simv').is_file():raise ValueError('build inputs changed')
    else:
        build.mkdir()
        (build/'files.f').write_text('\n'.join(str(p) for p in sources)+'\n')
        (build/'coverage.hier').write_text('+tree tb_kse_stream.dut\n+tree tb_kse_stream.link\n')
        m={'files':inputs,'top':'tb_kse_stream','parameters':{n:int(v) for n,v in re.findall(r'parameter int\s+(R|C|SM_LANES|LN_LANES|PF_DEPTH)\s*=\s*(\d+)', (REPO/'rtl/kse/kse_top.sv').read_text())},
           'macro_models':macros,'initialization':'strict four-state; no initreg','data_manifest_sha256':data_hash}
        save(build/'source_manifest.json',m)
        cmd=['vcs','-full64','-sverilog','-ntb_opts','uvm-1.2','-timescale=1ns/1ps','-kdb','-debug_access+all','-assert','svaext','-lca',
             '-top','tb_kse_stream','-f',str(build/'files.f'),'-Mdir='+str(build/'csrc'),'-o',str(build/'simv'),'-l',str(build/'compile.log'),
             '-cm',CM,'-cm_dir',str(build/'cov.vdb'),'-cm_hier',str(build/'coverage.hier')]
        cmd += ['+define+'+n for n in mem['sim_defines']]+mem.get('sim_opts',[])
        rc=execute(cmd,build,'compile',1200)
        txt=(build/'compile.console.log').read_text(errors='replace')
        warnings=re.findall(r'Warning-\[([^]]+)\]',txt)
        allowed=all(w=='LCA_FEATURES_ENABLED' for w in warnings)
        passed=rc==0 and (build/'simv').is_file() and allowed and not re.search(r'Error-|Fatal-|^Warning\s*:',txt,re.M)
        save(build/'compile_result.json',{'returncode':rc,'warnings':warnings,'pass':passed})
        if not passed:
            write_record(out,inputs,{'pass':False,'compile_failed':True,'urg_returncode':None},a.seed,{'waves':a.waves})
            print('KSE_STREAM_COMPILE_FAILED',build);return 1
    (out/'build_path.txt').write_text(str(build)+'\n')
    save(out/'config.json',dict(vars(a),out=str(out),data=str(data),build=str(build)))
    if a.compile_only:print('KSE_STREAM_COMPILE_ONLY',build);return 0
    reports=[]
    kinds=['positive']+(['negative-value','negative-missing'] if a.negative else [])
    for kind in kinds:
        run=out/kind;run.mkdir()
        neg=kind!='positive'
        first=a.first;count=1 if neg else a.count;layers=1 if neg else a.layers
        args=[str(build/'simv'),'+UVM_TESTNAME=test_kse_stream','+UVM_VERBOSITY=UVM_LOW','+ntb_random_seed='+str(a.seed),
              '+DATA='+str(data),'+SAMPLE0='+str(first),'+SAMPLES='+str(count),'+LAYERS='+str(layers),
              '+MODE='+str(a.mode),'+OUTALL='+str(a.outall),'-l',str(run/'sim.log'),'-cm',CM,'-cm_dir',str(run/'cov.vdb'),'-cm_name',kind]
        if a.waves:args+=['+fsdbfile='+str(run/'wave.fsdb')]
        if kind=='negative-value':args+=['+KSE_CORRUPT_EXPECTED']
        if kind=='negative-missing':args+=['+KSE_DROP_CHECKPOINT']
        rc=execute(args,run,'sim',a.seconds)
        output=(run/'sim.console.log').read_bytes()+(run/'sim.log').read_bytes() if (run/'sim.log').exists() else (run/'sim.console.log').read_bytes()
        (run/'check_input.log').write_bytes(output)
        report=check_log(run/'check_input.log',rc,True,run/'wave.fsdb' if a.waves else None,'KSE_STREAM_COMPLETE')
        text=output.decode(errors='replace')
        accepted=report['verdict']=='PASS' and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)',text,re.M)
        if neg:
            pat=(rf'^UVM_ERROR .* \[KSE_GOLDEN\] sample={a.first} layer=0 tensor=14 token=0 col=0 got=([0-9a-f]{{2}}) expected=([0-9a-f]{{2}})$'
                 if kind=='negative-value' else rf'^UVM_ERROR .* \[KSE_MISSING\] sample={a.first} layer=0 tensor=1 count=6335 expected=6336$')
            matches=[line for line in text.splitlines() if re.fullmatch(pat,line)]
            clean='\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*',line) else line for line in text.splitlines() if not re.fullmatch(pat,line))+'\n'
            residual_path=run/'negative-residual.log';residual_path.write_text(clean)
            residual=check_log(residual_path,rc,True,run/'wave.fsdb' if a.waves else None,'KSE_STREAM_COMPLETE')
            save(run/'negative-residual.json',residual)
            accepted=len(set(matches))==1 and report['verdict']=='FAIL' and report['counts']=={'UVM_ERROR':1,'UVM_FATAL':0} and residual['verdict']=='PASS'
        save(run/'result.json',report)
        simlog=(run/'sim.log').read_text(errors='replace')
        counters=[line.split('] ',1)[-1] for line in simlog.splitlines() if re.search(r'\[KSE_(LAYER|COMPARE|TRAFFIC|ENGINE_CONFIG)\]',line)]
        reports.append({'kind':kind,'accepted':accepted,'observed_verdict':report['verdict'],'counters':counters,
                        'designated_errors':sorted(set(matches)) if neg else [],
                        'residual_verdict':residual['verdict'] if neg else None})
        print(json.dumps(reports[-1]),flush=True)
        if not accepted:break
    rc=execute(['urg','-full64','-dir',str(build/'cov.vdb'),str(out/'positive/cov.vdb'),'-report',str(out/'urgReport'),'-format','both'],out,'urg',240) if reports[0]['accepted'] else -1
    unchanged=all(sha(Path(p))==h for p,h in inputs.items()) and validate_data(data)==data_hash
    passed=all(t['accepted'] for t in reports) and len(reports)==len(kinds) and rc==0 and (out/'urgReport/dashboard.txt').is_file() and unchanged
    summary={'tests':reports,'urg_returncode':rc,'inputs_unchanged':unchanged,'pass':passed,'scope':m['parameters']}
    save(out/'summary.json',summary)
    write_record(out,inputs,summary,a.seed,dict(first=a.first,count=a.count,layers=a.layers,mode=a.mode,outall=a.outall,waves=a.waves))
    print('KSE_STREAM_'+('DONE' if passed else 'FAILED'),out/'summary.json')
    return 0 if passed else 1


if __name__=='__main__':raise SystemExit(main())
