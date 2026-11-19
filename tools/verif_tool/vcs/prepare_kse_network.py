#!/usr/bin/env python3
"""Convert the SHA-bound independent-engine data to all 24 SoC loader images."""
import argparse
import hashlib
import json
from pathlib import Path
from run_kse_stream import validate_data


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stream-data', required=True, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    a = ap.parse_args()
    src = a.stream_data.resolve()
    before = validate_data(src)
    source_manifest = json.loads((src / 'data_manifest.json').read_text())
    params = (src / 'params/params.bin').read_bytes()
    if len(params) != 79008 * 4:
        raise ValueError('wrong v3 parameter length')
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    generated, bindings, tasks = {}, {}, []
    for sample in range(24):
        inputs = []
        for name in ['sample_input', 'sample_output']:
            p = src / 'samples' / f's{sample:02d}_{name}.hex'
            spec = source_manifest['outputs'][str(p)]
            if sha(p) != spec['sha256']:
                raise ValueError('unbound byte stream')
            words = p.read_text().splitlines()
            if len(words) != 6336 or any(len(w) != 2 for w in words):
                raise ValueError('unexpected byte hex format')
            inputs.append(bytes(int(w, 16) for w in words))
            bindings[str(p)] = spec
        ib, ob = inputs
        for suffix, data in [('img', ib + params), ('out', ob)]:
            p = out / f'sample_{sample:02d}_{suffix}.hex'
            p.write_text(''.join(f'{int.from_bytes(data[i:i+4], "little"):08x}\n' for i in range(0, len(data), 4)))
            generated[str(p)] = {'sha256': sha(p), 'bytes': p.stat().st_size}
        tasks.append({'sample': sample, 'image_words': 80592, 'output_words': 1584,
                      'input_sha256': hashlib.sha256(ib).hexdigest(), 'output_sha256': hashlib.sha256(ob).hexdigest()})
    bindings[str(src / 'params/params.bin')] = source_manifest['outputs'][str(src / 'params/params.bin')]
    if validate_data(src) != before:
        raise ValueError('source data changed during conversion')
    manifest = {'candidate': source_manifest['candidate'], 'samples': 24, 'layers': 12,
                'source_manifest': str(src / 'data_manifest.json'), 'source_manifest_sha256': before,
                'inputs': bindings, 'outputs': generated, 'tasks': tasks,
                'conversion': 'input bytes followed by independently decoded v3 params; output bytes only; no arithmetic oracle recomputation'}
    (out / 'data_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('KSE_NETWORK_DATA_PASSED samples=24 image_words=80592 output_words=1584')


if __name__ == '__main__':
    main()
