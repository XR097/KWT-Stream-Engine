#!/usr/bin/env python3
"""Build and run numerical UVM against immutable integer/ROM vectors."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex

from check_log import check_log
from run_kse_bootstrap import execute as raw_execute

REPO=Path(__file__).resolve().parents[3]
CM='line+cond+fsm+tgl+branch+assert'


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2)+'\n')



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
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--data',type=Path,required=True);ap.add_argument('--build',type=Path)
    ap.add_argument('--seed',type=int,default=1);ap.add_argument('--negative',action='store_true');ap.add_argument('--waves',action='store_true')
    a=ap.parse_args();out=a.out.resolve();data=a.data.resolve();manifest=json.loads((data/'manifest.json').read_text())
    if sha(data/'numeric.txt')!=manifest['vectors_sha256']:raise ValueError('vectors changed')
    for p,h in manifest['inputs'].items():
        if sha(Path(p))!=h:raise ValueError('ROM source changed')
    sources=[REPO/'rtl/kse'/(n+'.sv') for n in ['kse_arith','kse_exp_rom','kse_gelu_rom','kse_post','kse_softmax']]
    sources += [REPO/'verification/uvm/kse'/n for n in ['kse_numeric_if.sv','kse_numeric_pkg.sv','tb_kse_numeric.sv']]
    controls=[Path(__file__).resolve(),Path(__file__).with_name('prepare_kse_numeric.py'),Path(__file__).with_name('check_log.py'),Path(__file__).with_name('run_kse_bootstrap.py'),data/'manifest.json',data/'numeric.txt']
    inputs={str(p):sha(p) for p in sources+controls};out.mkdir(parents=True,exist_ok=False)
    build=a.build.resolve() if a.build else out/'build'
    if a.build:
        if json.loads((build/'source_manifest.json').read_text())['files']!=inputs:raise ValueError('build inputs changed')
    else:
        build.mkdir();save(build/'source_manifest.json',{'files':inputs,'top':'tb_kse_numeric','parameters':'shift25/32 left7, sat32/8, div23/22/8 and38/24/30 BPS2, sqrt36 BPC2/3, production ROM/post','initialization':'strict four-state; no initreg'})
        (build/'files.f').write_text('\n'.join(str(p) for p in sources)+'\n');(build/'coverage.hier').write_text('+tree tb_kse_numeric\n')
        cmd=['vcs','-full64','-sverilog','-ntb_opts','uvm-1.2','-timescale=1ns/1ps','-debug_access+all','-kdb','-lca','-top','tb_kse_numeric','-f',str(build/'files.f'),
             '-Mdir='+str(build/'csrc'),'-o',str(build/'simv'),'-l',str(build/'compile.log'),'-cm',CM,'-cm_dir',str(build/'cov.vdb'),'-cm_hier',str(build/'coverage.hier')]
        rc=execute(cmd,build,'compile',600);txt=(build/'compile.console.log').read_text(errors='replace');warnings=re.findall(r'Warning-\[([^]]+)\]',txt)
        ok=rc==0 and (build/'simv').is_file() and len(warnings)<=1 and all(w=='LCA_FEATURES_ENABLED' for w in warnings) and not re.search(r'Error-|Fatal-|^Warning\s*:',txt,re.M)
        save(build/'compile_result.json',{'pass':ok,'returncode':rc,'warnings':warnings})
        if not ok:
            write_record(out,inputs,{'pass':False,'compile_failed':True,'urg_returncode':None},a.seed,{'waves':a.waves})
            print('KSE_NUM_COMPILE_FAILED',build);return 1
    (out/'build_path.txt').write_text(str(build)+'\n');reports=[]
    for neg in ([False,True] if a.negative else [False]):
        run=out/('negative' if neg else 'positive');run.mkdir()
        cmd=[str(build/'simv'),'+UVM_TESTNAME=test_kse_numeric','+ntb_random_seed='+str(a.seed),'+VECTORS='+str(data/'numeric.txt'),'-l',str(run/'sim.log'),
             '-cm',CM,'-cm_dir',str(run/'cov.vdb'),'-cm_name','negative' if neg else 'positive']
        if a.waves:cmd+=['+fsdbfile='+str(run/'wave.fsdb')]
        if neg:cmd+=['+KSE_NUM_CORRUPT_EXPECTED']
        rc=execute(cmd,run,'sim',180);console=(run/'sim.console.log').read_text(errors='replace');log=(run/'sim.log').read_text(errors='replace') if (run/'sim.log').exists() else ''
        text=console+log;(run/'check_input.log').write_text(text)
        result=check_log(run/'check_input.log',rc,True,run/'wave.fsdb' if a.waves else None,'KSE_NUM_COMPLETE');save(run/'result.json',result)
        expected={int(k):v for k,v in manifest['counts'].items()};expected[9]=expected[4]
        counts={int(op):(int(acc),int(cmp)) for op,acc,cmp in re.findall(r'\[KSE_NUM_COUNT\] op=(\d+) accepted=(\d+) compared=(\d+)',log)}
        complete=counts=={op:(n,n) for op,n in expected.items()}
        ok=result['verdict']=='PASS' and complete and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)',text,re.M)
        if neg:
            pattern=r'^UVM_ERROR .* \[KSE_NUM_SB\] op=0 index=0 got=0000000080000000 expected=0000000080000001$'
            matches=[line for line in text.splitlines() if re.fullmatch(pattern,line)]
            cleaned='\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*',line) else line for line in text.splitlines() if not re.fullmatch(pattern,line))+'\n'
            path=run/'negative-residual.log';path.write_text(cleaned);residual=check_log(path,rc,True,run/'wave.fsdb' if a.waves else None,'KSE_NUM_COMPLETE');save(run/'negative-residual.json',residual)
            ok=len(set(matches))==1 and result['verdict']=='FAIL' and result['counts']=={'UVM_ERROR':1,'UVM_FATAL':0} and residual['verdict']=='PASS' and complete
        reports.append({'negative':neg,'accepted':ok,'observed_verdict':result['verdict'],'counts':counts});print(json.dumps(reports[-1]),flush=True)
        if not ok:break
    rc=execute(['urg','-full64','-dir',str(build/'cov.vdb'),str(out/'positive/cov.vdb'),'-report',str(out/'urgReport'),'-format','both'],out,'urg',180) if reports[0]['accepted'] else -1
    unchanged=all(sha(Path(p))==h for p,h in inputs.items());passed=all(r['accepted'] for r in reports) and len(reports)==(2 if a.negative else 1) and rc==0 and unchanged
    summary={'tests':reports,'inputs_unchanged':unchanged,'urg_returncode':rc,'pass':passed}
    save(out/'summary.json',summary)
    write_record(out,inputs,summary,a.seed,{'waves':a.waves})
    print('KSE_NUM_'+('DONE' if passed else 'FAILED'),out/'summary.json')
    return 0 if passed else 1


if __name__=='__main__':raise SystemExit(main())
