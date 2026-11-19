#!/usr/bin/env python3
"""KSNUM-012 directed LayerNorm vectors with two RTL-independent oracles.

Oracle A: pure Python integers written from docs/spec/kse_top.md sec. 6
          (RNE shift, RNE divide, floor isqrt, sat8) -- no NumPy, no RTL.
Oracle B: the normative bit model quantization/hardware_model.py
          (HardwareEncoder._residual / layernorm / _sat) driven through a
          minimal synthetic profile.  Only usable for "tied" parameter sets
          (vsh = -(2e_res+24), nsh = -(e_res+24), ash = e_out+24), which is
          every production layer and every synthetic set except two
          explicitly untied range-corner sets (Oracle A only).
Every token where both oracles apply must agree byte-for-byte, otherwise
generation aborts.  RTL results are never used as expectations.

Output: <out>/ln_vectors.txt (TB input), <out>/manifest.json.
Run with a Python that has NumPy (e.g. python3 -B).
"""
import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
GOLDEN = REPO / 'kwt-data/golden/9498911f415c30adccc1_middle'


# ---------------- Oracle A: pure integers ----------------
def shift_rne(v, s):
    if s <= 0:
        return v << (-s)
    m = abs(v)
    q, r = m >> s, m & ((1 << s) - 1)
    h = 1 << (s - 1)
    if r > h or (r == h and (q & 1)):
        q += 1
    return -q if v < 0 else q


def div_rne(n, d):
    assert d > 0
    m = abs(n)
    q, r = divmod(m, d)
    if 2 * r > d or (2 * r == d and (q & 1)):
        q += 1
    return -q if n < 0 else q


def isqrt(n):
    assert n >= 0
    x = 0
    for b in range(40, -1, -1):
        t = x | (1 << b)
        if t * t <= n:
            x = t
    return x


def sat(v, lo=-128, hi=127):
    return lo if v < lo else hi if v > hi else v


def oracle_a(x, y, p):
    r = [sat(shift_rne(a, p['ax']) + shift_rne(b, p['ay'])) for a, b in zip(x, y)]
    s = sum(r)
    c = [64 * v - s for v in r]
    ss = sum(v * v for v in c)
    var = div_rne(ss, 1 << 18)
    vq = shift_rne(var, p['vsh']) + p['eps']
    root = isqrt(vq)
    den = 64 * root
    out, qmax = [], 0
    for e, v in enumerate(c):
        n = div_rne(shift_rne(v, p['nsh']), den)
        qmax = max(qmax, abs(n))
        out.append(sat(shift_rne(n * p['gamma'][e], p['ash']) + p['beta'][e]))
    stats = {'S': s, 'ss': ss, 'var': var, 'vq': vq, 'root': root, 'qmax': qmax}
    return r, out, stats


# ---------------- Oracle B: quantization/hardware_model.py ----------------
class OracleB:
    def __init__(self):
        sys.path.insert(0, str(REPO))
        import numpy as np
        from quantization.hardware import HardwareEncoder
        self.np, self.cls = np, HardwareEncoder

    def run(self, x, y, p):
        np = self.np
        e = p['exp']
        params = {'exponents': {'x': e['x'], 'y': e['y'], 'res': e['res'], 'out': e['out']},
                  'activation_bits': 8, 'accumulator_bits': 64, 'residual_accumulator_bits': 64,
                  'norms': {'ln': {'size': 64, 'input': 'res', 'output': 'out', 'epsilon_q24': p['eps']}},
                  'layernorm_configs': {'ln': {'method': 'reference', 'norm_frac': 12, 'gamma_frac': 12}}}
        arrays = {'ln.gamma': np.array(p['gamma'], dtype=np.int64), 'ln.beta': np.array(p['beta'], dtype=np.int64)}
        hw = self.cls(params, arrays)
        xa = np.array([x], dtype=np.int64)
        ya = np.array([y], dtype=np.int64)
        r = hw._residual(xa, 'x', ya, 'y', 'res', False)
        o = hw._sat(hw.layernorm(r, 'ln', False), key='out')
        return [int(v) for v in r[0]], [int(v) for v in o[0]]


def tied(e_x, e_y, e_res, e_out):
    return {'ax': e_res - e_x, 'ay': e_res - e_y, 'vsh': -(2 * e_res + 24), 'nsh': -(e_res + 24),
            'ash': e_out + 24, 'exp': {'x': e_x, 'y': e_y, 'res': e_res, 'out': e_out}}


def check_ranges(p):
    # docs/spec/kse_top.md sec. 5: residual align in [-7,15], vsh [-20,0], nsh [-23,0], ash [0,20]
    assert -7 <= p['ax'] <= 15 and -7 <= p['ay'] <= 15, p
    assert -20 <= p['vsh'] <= 0 and -23 <= p['nsh'] <= 0 and 0 <= p['ash'] <= 20, p
    assert 0 <= p['eps'] <= 65535 and all(0 <= g <= 65535 for g in p['gamma'])
    assert all(-128 <= b <= 127 for b in p['beta']) and len(p['gamma']) == 64 == len(p['beta'])


# ---------------- row construction (residual rows r with y=0, ax=0 unless stated) ----------------
def row_classes(rng):
    rows = []
    for v in (-128, -1, 0, 1, 127, 37):
        rows.append(('constant', [v] * 64))
    rows.append(('extreme', [-128] * 32 + [127] * 32))                 # maximum variance
    rows.append(('extreme', [127 if i % 2 else -128 for i in range(64)]))
    rows.append(('extreme', [-128] * 63 + [127]))                      # single outlier
    rows.append(('extreme', [127] * 63 + [-128]))
    rows.append(('extreme', [0] * 63 + [127]))
    rows.append(('alternating', [(-1) ** i for i in range(64)]))       # S=0, var=1
    rows.append(('alternating', [(-1) ** i * 127 for i in range(64)]))
    rows.append(('alternating', [(-1) ** (i // 2) * (i + 1) for i in range(64)]))
    rows.append(('alternating', [(5 if i % 2 else -3) for i in range(64)]))   # offset mean
    # variance boundaries: square_sum = 64*(64Q - S^2); RNE(ss / 2^18)
    rows.append(('var_tie_half', [1] * 16 + [-1] * 16 + [0] * 32))     # ss=2^17 -> var 0 (tie, even)
    rows.append(('var_one', [1] * 32 + [-1] * 32))                     # ss=2^18 -> var 1
    rows.append(('var_tie_1p5', [2] * 12 + [-2] * 12 + [0] * 40))     # ss=1.5*2^18 -> var 2 (tie, even)
    rows.append(('var_tie_2p5', [2] * 20 + [-2] * 20 + [0] * 24))     # ss=2.5*2^18 -> var 2 (tie, even)
    rows.append(('var_0p75', [1] * 24 + [-1] * 24 + [0] * 16))        # ss=0.75*2^18 -> var 1
    rows.append(('var_small', [0] * 63 + [1]))                         # ss=4032 -> var 0, c!=0
    rows.append(('var_small', [0] * 62 + [1, -1]))
    for _ in range(6):
        rows.append(('random', [rng.randint(-128, 127) for _ in range(64)]))
    return rows


def classify(r, st):
    tags = []
    if len(set(r)) == 1:
        tags.append('constant_row')
    if -128 in r or 127 in r:
        tags.append('extreme_value')
    if all(r[i] * r[i + 1] < 0 for i in range(63)):
        tags.append('sign_alternating')
    if st['ss'] % (1 << 18) == (1 << 17):
        tags.append('variance_rne_tie')
    if st['var'] <= 2:
        tags.append('variance_le2')
    if st['var'] == 0 and st['ss'] != 0:
        tags.append('variance_round_to_zero_nonconst')
    if st['var'] >= 16000:
        tags.append('variance_max_region')
    if st['root'] * st['root'] == st['vq']:
        tags.append('isqrt_perfect_square')
    if (st['root'] + 1) ** 2 == st['vq'] + 1:
        tags.append('isqrt_below_square')
    return tags


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--seed', type=int, default=20261111)
    ap.add_argument('--stream-tokens', type=int, default=240)
    a = ap.parse_args()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    rng = random.Random(a.seed)
    ob = OracleB()
    import numpy as np
    profile_path = GOLDEN / 'profile/profile.json'
    prof = json.loads(profile_path.read_text())
    sets = []

    def add_set(name, kind, p, tokens, gaps=None):
        check_ranges(p)
        sets.append({'name': name, 'kind': kind, 'p': p, 'tokens': tokens, 'gaps': gaps})

    # 1) production LN parameters, all 24 LayerNorms of the frozen profile
    base_rows = row_classes(rng)
    for b in prof['blocks']:
        ex = lambda n: int(prof['exponents'][b + '.' + n])
        for ln, (xk, yk, rk, ok) in (('ln1', ('input', 'proj', 'res1', 'ln1')), ('ln2', ('ln1', 'fc2', 'res2', 'output'))):
            p = tied(ex(xk), ex(yk), ex(rk), ex(ok))
            key = b + '.' + ln
            p['eps'] = int(prof['norms'][key]['epsilon_q24'])
            p['gamma'] = [int(v) for v in np.load(GOLDEN / 'profile' / prof['arrays'][key + '.gamma']['file'])]
            p['beta'] = [int(v) for v in np.load(GOLDEN / 'profile' / prof['arrays'][key + '.beta']['file'])]
            toks = []
            for cls, r in base_rows:
                if p['ax'] == 0:
                    toks.append((cls, r, [0] * 64))
                else:   # keep the class by driving it through y when ay==0, else drive x with y=0
                    toks.append((cls, r, [0] * 64) if p['ax'] >= 0 else (cls, [v >> (-p['ax']) for v in r], [0] * 64))
            # real-scale residual pairs (x,y random) and saturating pairs
            for _ in range(4):
                toks.append(('random_pair', [rng.randint(-128, 127) for _ in range(64)], [rng.randint(-128, 127) for _ in range(64)]))
            toks.append(('residual_saturation', [127] * 32 + [-128] * 32, [127] * 32 + [-128] * 32))
            add_set('prod_' + key, 'production', p, toks)

    # 2) synthetic parameter corners (tied unless stated)
    alt_gamma = [65535 if i % 2 else 0 for i in range(64)]
    ramp_gamma = [4096 + 97 * i for i in range(64)]
    ramp_beta = [((i * 37) % 256) - 128 for i in range(64)]
    corners = [
        ('ax_m7_ay_15', tied(4, -12, -3, -5), 17, ramp_gamma, ramp_beta),        # ax=-7 (left 7), ay=+9
        ('ax_15_ay_m7', tied(-18, 4, -3, -5), 17, ramp_gamma, ramp_beta),        # ax=15, ay=-7
        ('vsh0_e_m12', tied(-12, -12, -12, -10), 17, ramp_gamma, [0] * 64),      # vsh=0, nsh=-12
        ('vsh_m20_e_m2', tied(-2, -2, -2, -4), 17, ramp_gamma, [0] * 64),         # vsh=-20, nsh=-22
        ('ash0', tied(-3, -3, -3, -24), 17, ramp_gamma, ramp_beta),               # ash=0
        ('ash20', tied(-3, -3, -3, -4), 17, ramp_gamma, ramp_beta),               # ash=20
        ('eps1', tied(-3, -3, -3, -4), 1, ramp_gamma, ramp_beta),
        ('eps65535', tied(-3, -3, -3, -4), 65535, ramp_gamma, ramp_beta),
        ('gamma_alt_0_max', tied(-3, -3, -3, -6), 17, alt_gamma, [(-128 if i % 3 == 0 else 127) for i in range(64)]),
        ('gamma0_beta_ext', tied(-3, -3, -3, -4), 17, [0] * 64, [(-128, 127, -1, 0)[i % 4] for i in range(64)]),
    ]
    for name, p, eps, g, bta in corners:
        p = dict(p, eps=eps, gamma=list(g), beta=list(bta))
        toks = [(cls, r, [0] * 64) if p['ax'] == 0 else (cls, [0] * 64, r) if p['ay'] == 0 else (cls, r, [0] * 64) for cls, r in base_rows]
        for _ in range(3):
            toks.append(('random_pair', [rng.randint(-128, 127) for _ in range(64)], [rng.randint(-128, 127) for _ in range(64)]))
        add_set('corner_' + name, 'corner', p, toks)
    # untied range corners (Oracle A only)
    for name, vsh, nsh in (('untied_vsh_m20_nsh_m23', -20, -23), ('untied_vsh0_nsh0', 0, 0)):
        p = {'ax': 0, 'ay': 0, 'vsh': vsh, 'nsh': nsh, 'ash': 20 if nsh == -23 else 0, 'eps': 17,
             'gamma': ramp_gamma, 'beta': ramp_beta, 'exp': None}
        toks = [(cls, r, [0] * 64) for cls, r in base_rows]
        add_set('corner_' + name, 'untied', p, toks)

    # 3) isqrt boundaries: choose eps so vq = m^2 - 1, m^2, m^2 + 1 for a fixed variance row
    p0 = tied(-3, -3, -3, -4)
    row = [1] * 32 + [-1] * 32           # var = 1 -> vq = 2^18 + eps (e=-3 -> vsh=-18)
    for m, d in ((513, -1), (513, 0), (513, 1), (540, -1), (540, 0), (572, 0)):
        eps = m * m + d - (1 << 18)
        p = dict(p0, eps=eps, gamma=ramp_gamma, beta=ramp_beta)
        toks = [('isqrt_boundary', row, [0] * 64), ('isqrt_boundary', [3] * 32 + [-3] * 32, [0] * 64)]
        add_set('isqrt_m%d_d%+d' % (m, d), 'isqrt', p, toks)

    # 4) token/tag alignment stream: production b05.ln2 params, many tokens, gaps 0 or random
    prod = next(s for s in sets if s['name'] == 'prod_b05.ln2')['p']
    for gap_mode in ('back_to_back', 'random_gaps'):
        toks, gaps = [], []
        for t in range(a.stream_tokens):
            kind = t % 6
            if kind == 0:
                r = [rng.randint(-128, 127)] * 64
            elif kind == 1:
                m = rng.randint(1, 127)
                r = [m if (i + t) % 2 else -m for i in range(64)]
            else:
                r = [rng.randint(-128, 127) for _ in range(64)]
            toks.append(('stream', r, [rng.randint(-20, 20) for _ in range(64)]))
            gaps.append((0, 0) if gap_mode == 'back_to_back' else (rng.choice((0, 0, 1, 3)), rng.choice((0, 0, 1, 2, 7))))
        add_set('stream_' + gap_mode, 'stream', prod, toks, gaps)

    # ---- evaluate oracles ----
    lines, counts, tags_count, both, only_a, qmax = [], {}, {}, 0, 0, 0
    for si, s in enumerate(sets):
        p = s['p']
        gam = sum((g & 0xFFFF) << (16 * e) for e, g in enumerate(p['gamma']))
        bet = sum((b & 0xFF) << (8 * e) for e, b in enumerate(p['beta']))
        lines.append('S %d %d %d %d %d %d %d %d %0256x %0128x' % (si, p['ax'], p['ay'], p['vsh'], p['nsh'], p['ash'],
                                                                  p['eps'], len(s['tokens']), gam, bet))
        for ti, (cls, x, y) in enumerate(s['tokens']):
            x = [sat(v) for v in x]
            y = [sat(v) for v in y]
            r, o, st = oracle_a(x, y, p)
            qmax = max(qmax, st['qmax'])
            if p.get('exp') is not None:
                rb, obb = ob.run(x, y, p)
                if rb != r or obb != o:
                    raise SystemExit('ORACLE_MISMATCH set=%s token=%d' % (s['name'], ti))
                both += 1
            else:
                only_a += 1
            pk = lambda vals: sum((v & 0xFF) << (8 * e) for e, v in enumerate(vals))
            g = s['gaps'][ti] if s['gaps'] else (rng.choice((0, 1)), rng.choice((0, 0, 2)))
            lines.append('T %d %d %0128x %0128x %0128x %0128x %d %d' % (si, ti, pk(x), pk(y), pk(r), pk(o), g[0], g[1]))
            counts[s['kind']] = counts.get(s['kind'], 0) + 1
            for t in classify(r, st) + ['construct:' + cls]:
                tags_count[t] = tags_count.get(t, 0) + 1
    text = '\n'.join(lines) + '\n'
    (out / 'ln_vectors.txt').write_text(text)
    sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
    manifest = {'vectors_sha256': hashlib.sha256(text.encode()).hexdigest(), 'sets': len(sets),
                'tokens': sum(counts.values()), 'tokens_by_kind': counts, 'row_tags': dict(sorted(tags_count.items())),
                'oracle_both_tokens': both, 'oracle_a_only_tokens': only_a, 'max_abs_quotient': qmax,
                'quotient_clamp_threshold': (1 << 30) - 1, 'seed': a.seed,
                'set_names': [s['name'] for s in sets],
                'inputs': {str(p): sha(p) for p in [Path(__file__).resolve(), profile_path, REPO / 'quantization/hardware_model.py',
                                                     REPO / 'quantization/encoding.py']},
                'numpy': np.__version__, 'python': sys.version.split()[0]}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('WP8_LN_VECTORS', json.dumps({k: manifest[k] for k in ('sets', 'tokens', 'oracle_both_tokens', 'oracle_a_only_tokens', 'max_abs_quotient')}))


if __name__ == '__main__':
    main()
