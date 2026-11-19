#!/usr/bin/env python3
"""Create and verify a reproducible KSE UVM source manifest."""
import argparse, hashlib, json, pathlib, subprocess, sys
EXTENSIONS={'.v','.vh','.sv','.svh','.f'}
def inventory(repo):
 result={}
 for folder in ('rtl/kse','rtl/kse_soc','third-party/e203/rtl','verification/uvm/kse','verification/uvm/wp8_kse'):
  root=repo/folder
  if not root.is_dir(): continue
  for path in sorted(root.rglob('*')):
   if path.is_file() and path.suffix in EXTENSIONS and '__pycache__' not in path.parts:
    result[path.relative_to(repo).as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
 for path in sorted((repo/'tools/verif_tool/vcs').glob('*.py')):
  result[path.relative_to(repo).as_posix()]=hashlib.sha256(path.read_bytes()).hexdigest()
 return result
def source_list(repo):
 paths=[]
 for folder in ('rtl/kse','rtl/kse_soc','verification/uvm/kse','verification/uvm/wp8_kse'):
  root=repo/folder
  if root.is_dir(): paths.extend(p for p in sorted(root.rglob('*')) if p.is_file() and p.suffix in {'.v','.sv','.svh'})
 return paths
def main():
 ap=argparse.ArgumentParser(); ap.add_argument('action',choices=('create','verify')); ap.add_argument('--repo',type=pathlib.Path,required=True); ap.add_argument('--build',type=pathlib.Path,required=True); ap.add_argument('--config',required=True); a=ap.parse_args(); repo,build=a.repo.resolve(),a.build.resolve(); current={'config':a.config,'files':inventory(repo)}; manifest=build/'source_manifest.json'
 if a.action=='verify':
  saved=json.loads(manifest.read_text());
  if saved != current: raise ValueError('sources/options changed since compilation')
  print('source fingerprint matches compiled inputs'); return
 build.mkdir(parents=True,exist_ok=True)
 if manifest.exists(): raise ValueError('refusing to overwrite existing build manifest')
 try: current['git_head']=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],stderr=subprocess.DEVNULL,text=True).strip()
 except (OSError,subprocess.CalledProcessError): current['git_head']='unavailable'
 manifest.write_text(json.dumps(current,indent=2,sort_keys=True)+'\n'); paths=source_list(repo); (build/'kse_uvm.f').write_text('\n'.join(str(p) for p in paths)+'\n'); print('prepared {} source entries; {} hashed inputs'.format(len(paths),len(current['files'])))
if __name__=='__main__':
 try: main()
 except (OSError,ValueError,KeyError) as exc: print('ERROR: '+str(exc),file=sys.stderr); raise SystemExit(2)
