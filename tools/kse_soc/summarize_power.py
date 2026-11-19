#!/usr/bin/env python3
"""Summarize actual PrimePower outputs; all powers in W, no estimates.
Usage: summarize_power.py <run_power.sh output directory> > summary.json
"""
import collections
import csv
import json
import pathlib
import sys


def rows(path):
    with path.open() as f:
        return list(csv.DictReader(f, delimiter='\t'))


def summarize(path):
    ps = {r['component']: [float(r[k]) for k in
          ('internal_W', 'switching_W', 'leakage_W', 'total_W')]
          for r in rows(path / 'power_components.tsv')}
    def sub(a, b): return [x-y for x, y in zip(a, b)]
    def macro_sum(fragment):
        return [sum(v[i] for k, v in ps.items() if fragment in k)
                for i in range(4)]
    tcm = macro_sum('/u_e203_srams/')
    shared = macro_sum('/u_shram/')
    parts = {'E203_without_TCM': sub(ps['cpu'], tcm), 'TCM_macros': tcm,
             'engine': ps['engine'], 'shared_macros': shared}
    parts['interconnect_and_other'] = [ps['soc'][i] - sum(v[i] for v in parts.values()) for i in range(4)]
    sources = collections.Counter((r['direction'], r['source'])
                                  for r in rows(path / 'macro_activity.tsv'))
    default = [sum(float(r[k]) for r in rows(path / 'default_cells.tsv'))
               for k in ('internal_W', 'switching_W', 'leakage_W', 'total_W')]
    return {'source': str(path), 'soc_W': ps['soc'], 'components_W': parts,
            'macro_pin_sources': {f'{d}/{s}': n for (d,s),n in sorted(sources.items())},
            'default_touch_cells_W': default,
            'default_touch_cells_power_fraction': default[3] / ps['soc'][3]}


def main():
    root = pathlib.Path(sys.argv[1])
    points = {rate: summarize(root / f'tr_{rate}') for rate in ('0.1', '0.0', '0.2')}
    # Duration comes from the SAIF header; supply it explicitly, never assume
    # the pre-pipeline cycle count. Unit ns, divided by actual task count 12.
    if len(sys.argv) == 3:
        duration_ns = float(sys.argv[2])
        points['energy_J_per_task'] = points['0.1']['soc_W'][3] * duration_ns * 1e-9 / 12
    points['delta_0.2_minus_0_W'] = points['0.2']['soc_W'][3] - points['0.0']['soc_W'][3]
    print(json.dumps(points, indent=2))

if __name__ == '__main__':
    main()
