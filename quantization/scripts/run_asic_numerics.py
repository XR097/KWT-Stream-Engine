"""Fresh, identity-bound ASIC experiments; batch checkpoints support --resume."""
import argparse
import os
import sys
from pathlib import Path
for key in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[key] = '1'
os.environ['CUDA_VISIBLE_DEVICES'] = '-1'
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from quantization.asic import run
if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data-root', required=True)
    p.add_argument('--repo-root', default='.')
    p.add_argument('--reference-root')
    p.add_argument('--workers', type=int, default=12)
    p.add_argument('--resume', action='store_true')
    p.add_argument('--stage', default='all', choices=('all','prepare','baseline','single','greedy','structure','nonlinear','final','stats','golden','report'))
    run(p.parse_args())
