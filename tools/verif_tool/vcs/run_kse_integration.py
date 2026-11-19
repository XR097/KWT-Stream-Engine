#!/usr/bin/env python3
"""Strict-final single-port arbitration/progress contract, isolated negative controls."""
import argparse
import json
import os
from pathlib import Path
import re

import yaml
from check_log import check_log
from kse_resources import e203_sources
from run_kse_bootstrap import execute
from run_kse_network import REPO, CM, sha, save

CASES = {
    'early': ('EARLY_DOORBELL', ['+NEGATIVE=early']),
    'rollback': ('WPTR_ROLLBACK', ['+NEGATIVE=rollback']),
    'grain': ('WPTR_GRAIN', ['+NEGATIVE=grain']),
    'done': ('DONE_PUBLICATION', ['+NEGATIVE=done']),
    'release': ('RELEASE_RULE', ['+NEGATIVE=release']),
    'arbitration': ('ARBITER', ['+CHECKER_MUTATION=arbitration']),
    'conservation': ('COUNTS', ['+CHECKER_MUTATION=conservation']),
    'cpu-bound': ('CPU_WAIT_BOUND', ['+CPU_WAIT_BOUND=0']),
    'x-payload': ('CMD_X', ['+INJECT_CMD_X']),
}

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--build', type=Path)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--x-negative', action='store_true', help='run only the CMD_X designated negative')
    ap.add_argument('--waves', action='store_true')
    ap.add_argument('--kind', choices=['shared'], default='shared')
    ap.add_argument('--priority', choices=[1], type=int, default=1)
    ap.add_argument('--model', choices=['pdk'], default='pdk')
    a = ap.parse_args()
    out = a.out.resolve();out.mkdir(parents=True, exist_ok=False)
    from kse_resources import memory_config
    pdk, mem = memory_config(REPO)
    e = e203_sources()
    sources = [e/'general'/n for n in ['sirv_gnrl_icbs.v','sirv_gnrl_dffs.v','sirv_gnrl_bufs.v','sirv_gnrl_xchecker.v']]
    sources += [REPO/'rtl/kse_soc'/f'{n}.sv' for n in ['kse_sram_ctrl','kse_sys_bus','kse_shared_sram']]
    sources += [Path(mem['v'].format(name='RAMSP4096X16'))]
    sources += [REPO/'verification/uvm/kse'/n for n in ['kse_integration_if.sv','kse_integration_pkg.sv','kse_contract_pkg.sv','tb_kse_shared_uvm.sv']]
    controls = [pdk,Path(__file__).resolve()]+[Path(__file__).with_name(n) for n in ['kse_resources.py','check_log.py','run_kse_bootstrap.py','run_kse_network.py']]
    hashes = {str(p):sha(p) for p in sources+controls}
    config = {'source_sha256':hashes,'top':'tb_kse_shared_uvm','priority':'DMA > loader > CPU','model':'pdk','initialization':'strict four state; no initreg'}
    build = a.build.resolve() if a.build else out/'build'
    if a.build:
        if json.loads((build/'source_manifest.json').read_text())!=config:
            raise ValueError('build source identity changed')
    else:
        build.mkdir();save(build/'source_manifest.json',config)
        (build/'files.f').write_text('\n'.join(map(str,sources))+'\n')
        cmd=['vcs','-full64','-sverilog','-ntb_opts','uvm-1.2','-timescale=1ns/1ps','-assert','svaext','-lca','-kdb','-debug_access+all','-top',config['top'],'-f',str(build/'files.f'),'-Mdir='+str(build/'csrc'),'-o',str(build/'simv'),'-l',str(build/'compile.log'),'-cm',CM,'-cm_dir',str(build/'cov.vdb')]
        cmd += ['+define+'+n for n in mem['sim_defines']]+mem.get('sim_opts',[])
        rc=execute(cmd,build,'compile',1200)
        text=(build/'compile.console.log').read_text(errors='replace')
        warnings=re.findall(r'Warning-\[([^]]+)\]',text)
        passed=rc==0 and (build/'simv').is_file() and all(w=='LCA_FEATURES_ENABLED' for w in warnings) and not re.search(r'Error-|Fatal-|^Warning\s*:',text,re.M)
        save(build/'compile_result.json',{'pass':passed,'rc':rc,'warnings':warnings})
        if not passed:
            save(out/'verification-record.json',{'pass':False,'stage':'compile','source_sha256':hashes,'seed':a.seed,'urg_rc':None})
            print('KSE_CONTRACT_COMPILE_FAILED',flush=True);return 1
    results=[]
    selected_cases = ['x-payload'] if a.x_negative else (list(CASES) if a.negative else [])
    for case in ['positive']+selected_cases:
        run=out/case;run.mkdir()
        cmd=[str(build/'simv'),'+UVM_TESTNAME=test_kse_contract','+UVM_VERBOSITY=UVM_LOW','+ntb_random_seed='+str(a.seed),'-l',str(run/'sim.log'),'-cm',CM,'-cm_dir',str(run/'cov.vdb'),'-cm_name',case]
        if a.waves:cmd+=['+fsdbfile='+str(run/'wave.fsdb')]
        if case!='positive':cmd+=CASES[case][1]
        rc=execute(cmd,run,'sim',180)
        text=(run/'sim.console.log').read_text(errors='replace')
        if (run/'sim.log').exists():text+=(run/'sim.log').read_text(errors='replace')
        (run/'check_input.log').write_text(text)
        result=check_log(run/'check_input.log',rc,True,run/'wave.fsdb' if a.waves else None,'KSE_CONTRACT_COMPLETE')
        accepted=result['verdict']=='PASS';hit=None
        if case!='positive':
            hit=CASES[case][0]
            pat=r'^UVM_ERROR .* \['+hit+r'\] .*'
            matches=re.findall(pat,text,re.M)
            clean='\n'.join('UVM_ERROR : 0' if re.fullmatch(r'\s*UVM_ERROR\s*:\s*1\s*',line) else line for line in text.splitlines() if not re.fullmatch(pat,line))+'\n'
            (run/'negative-residual.log').write_text(clean)
            residual=check_log(run/'negative-residual.log',rc,True,run/'wave.fsdb' if a.waves else None,'KSE_CONTRACT_COMPLETE')
            save(run/'negative-residual.json',residual)
            # Two transcripts may repeat one diagnostic. UVM summary must be exactly one.
            accepted=bool(matches) and result['counts']=={'UVM_ERROR':1,'UVM_FATAL':0} and residual['verdict']=='PASS' and not re.search(r'^UVM_WARNING(?!\s*:\s*0\s*$)',clean,re.M)
        save(run/'result.json',result)
        save(run/'verification-record.json',{'source_sha256':hashes,'command':json.loads((run/'sim.command.json').read_text()),'seed':a.seed,'pass':accepted,'observed_verdict':result['verdict'],'negative_hit':hit,'urg_rc':None,'metrics':re.findall(r'\[STRICT_BUS\] (.*)',text),'injection': 'checker observation/count mutation' if case in ('arbitration','conservation') else 'ICB stimulus or bound configuration'})
        results.append({'case':case,'accepted':accepted,'hit':hit});print(results[-1],flush=True)
        if not accepted:break
    urg_rc=None
    if results[0]['accepted']:
        urg_rc=execute(['urg','-full64','-dir',str(build/'cov.vdb'),str(out/'positive/cov.vdb'),'-report',str(out/'urgReport'),'-format','both'],out,'urg',240)
    unchanged=all(sha(Path(p))==h for p,h in hashes.items())
    passed=all(r['accepted'] for r in results) and unchanged and urg_rc==0 and (out/'urgReport/dashboard.txt').is_file()
    for r in results:
        p=out/r['case']/'verification-record.json';record=json.loads(p.read_text());record['urg_rc']=urg_rc;save(p,record)
    record={'pass':passed,'tests':results,'source_sha256':hashes,'seed':a.seed,'urg_rc':urg_rc,'inputs_unchanged':unchanged}
    save(out/'summary.json',record);save(out/'verification-record.json',record)
    print('KSE_CONTRACT_'+('DONE' if passed else 'FAILED'),flush=True)
    return 0 if passed else 1

if __name__=='__main__':raise SystemExit(main())
