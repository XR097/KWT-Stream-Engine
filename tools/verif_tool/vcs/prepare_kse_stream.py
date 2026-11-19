#!/usr/bin/env python3
"""Bind stream stimulus/checkpoints to the frozen manifest; no DUT-derived oracle.

Requires NumPy only for the existing offline parameter packer. Expected tensor
bytes come directly from SHA256-verified manifest binary files.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

import numpy as np

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'tools/kse'))
import pack_params as pp

NAMES = ('input','q','k','v','score','softmax','context','proj','res1','ln1','fc1','gelu','fc2','res2','output')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_identity(m,p):
    blocks=['b%02d'%i for i in range(12)]
    if (m['candidate']!='e3521354cc15f0877aef_middle' or m['count']!=24 or m['status']!='verified' or
        m['blocks']!=blocks or p['blocks']!=blocks or p['accumulator_bits']!=24 or p['rounding']!='nearest_even' or
        any(v!=4 for v in p['weight_bits_by_linear'].values())):raise ValueError('wrong frozen profile')
    if len(m['samples'])!=24 or [s['index'] for s in m['samples']]!=list(range(24)):
        raise ValueError('missing/duplicate/reordered sample')
    for sample in m['samples']:
        required={'input_int':[99,64],'output':[99,64]}
        for b in blocks:
            for name in NAMES:
                width=99 if name in ('score','softmax') else 256 if name in ('fc1','gelu') else 64
                required[b+'.'+name]=[99,width]
        for key,shape in required.items():
            spec=sample['tensors'][key]
            if spec['shape']!=shape or spec['bytes']!=shape[0]*shape[1] or spec['binary_dtype'] not in ('|i1','|u1'):
                raise ValueError('tensor shape/length/dtype: '+key)


def decode_parameters(root, out, profile):
    """Separate coordinate decoder: no pack_fields/unpack_fields/linear_fields.

    Offsets and exponent formulas are taken from the v3 specification. Values
    are compared against the original profile binary arrays, not packer output.
    """
    raw=(out/'params/params.bin').read_bytes()
    words=struct.unpack('<%dI' % (len(raw)//4),raw)
    pos=0; checked=0; pads=0
    def array(key):
        s=profile['arrays'][key]
        raw=(root/'profile'/s['binary']).read_bytes()
        if s['physical_encoding']=='signed_twos_complement_nibbles_low_first':
            values=[((v>>shift)&15)-16 if (v>>shift)&8 else (v>>shift)&15 for v in raw for shift in (0,4)]
            return np.array(values,dtype=np.int64).reshape(s['shape'])
        return np.frombuffer(raw,dtype=s['binary_dtype']).reshape(s['shape'])
    def signed(x,n): return x-(1<<n) if x & (1<<(n-1)) else x
    def equal(a,b,label):
        nonlocal checked
        if int(a)!=int(b): raise ValueError('v3 independent decode mismatch: '+label)
        checked+=1
    def take(n):
        nonlocal pos
        r=words[pos:pos+n];pos+=n
        if len(r)!=n:raise ValueError('short v3 stream')
        return r
    for b in profile['blocks']:
        begin=pos;e=lambda n:int(profile['exponents'][b+'.'+n])
        g=profile['gelu_configs'][b+'.gelu']
        h=take(8)
        fields=[e('score')-e('q')-e('k')-int(profile['attention_scale_exponent']),-8-e('score'),e('context')+7-e('v'),e('gelu')-e('fc1'),
                e('res1')-e('input'),e('res1')-e('proj'),e('res2')-e('ln1'),e('res2')-e('fc2'),
                -(2*e('res1')+24),-(e('res1')+24),e('ln1')+24,g['minimum_input'],
                -(2*e('res2')+24),-(e('res2')+24),e('output')+24,g['maximum_input']]
        for i,v in enumerate(fields):equal(signed((h[i//4]>>(8*(i%4)))&255,8),v,b+' header')
        for i,ln in enumerate(('ln1','ln2')):equal((h[4]>>(i*16))&65535,profile['norms'][b+'.'+ln]['epsilon_q24'],b+' epsilon')
        if any(h[5:]):raise ValueError('header padding')
        pads+=3
        def linear(name):
            nonlocal pads
            key=b+'.'+name;s=profile['linears'][key];k=s['in_features'];n=s['out_features']
            w=array(key+'.weight');bias=array(key+'.bias');we=array(key+'.weight_exponents')
            shift=int(profile['exponents'][s['output']])-int(profile['exponents'][s['input']])-we
            for cb in range(n//32):
                if name not in ('q','k','v'):
                    bw=take(16)
                    for c in range(32):equal(signed((bw[c//2]>>(16*(c%2)))&65535,16),bias[32*cb+c],key+' bias')
                elif np.any(bias):raise ValueError('nonzero omitted bias')
                sw=take(8)
                if sw[5]>>10 or any(sw[6:]):raise ValueError('shift padding')
                pads+=2
                for c in range(32):equal(signed((sw[c//6]>>(5*(c%6)))&31,5),shift[cb*32+c],key+' shift')
                ww=take(k*4)
                for r in range(k):
                    for c in range(32):equal(signed((ww[r*4+c//8]>>(4*(c%8)))&15,4),w[r,cb*32+c],key+' W4')
        def norm(name):
            gw=take(32);bw=take(16);gamma=array(b+'.'+name+'.gamma');beta=array(b+'.'+name+'.beta')
            for c in range(64):
                equal((gw[c//2]>>(16*(c%2)))&65535,gamma[c],b+' gamma')
                equal(signed((bw[c//4]>>(8*(c%4)))&255,8),beta[c],b+' beta')
        for name in ('q','k','v','proj'):linear(name)
        norm('ln1')
        for name in ('fc1','fc2'):linear(name)
        norm('ln2')
        if pos-begin!=6584:raise ValueError('layer word count')
    if pos!=79008 or pos!=len(words):raise ValueError('network word count')
    hx=[int(x,16) for x in (out/'params/params.hex').read_text().splitlines()]
    if hx!=list(words):raise ValueError('binary/hex mismatch')
    return {'words':pos,'values_checked':checked,'zero_pad_words':pads,'layers':12,'layer_words':6584}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--golden',type=Path,default=REPO/'kwt-data/golden/9498911f415c30adccc1_middle')
    ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();root=a.golden.resolve();out=a.out.resolve();out.mkdir(parents=True,exist_ok=False)
    m=json.loads((root/'sim_manifest.json').read_text());p=json.loads((root/m['profile']).read_text())
    validate_identity(m,p)
    inputs={};outputs={}
    def read(path,expected=None,size=None):
        path=path.resolve()
        if root not in path.parents:raise ValueError('manifest path escapes golden root')
        raw=path.read_bytes();h=hashlib.sha256(raw).hexdigest()
        if expected is not None and h!=expected:raise ValueError('golden hash mismatch: '+str(path))
        if size is not None and len(raw)!=size:raise ValueError('golden length mismatch: '+str(path))
        inputs[str(path)]={'sha256':h,'bytes':len(raw)};return raw
    for name in ('sim_manifest.json','golden_manifest.json','profile/profile.json'):
        read(root/name)
    for key,spec in p['arrays'].items():
        read(root/'profile'/spec['file'],spec['npy_sha256'])
        read(root/'profile'/spec['binary'],spec['binary_sha256'],spec['binary_bytes'])
    pp.pack(root/'profile',out/'params')
    n,c=pp.verify(root/'profile',out/'params')
    dec=decode_parameters(root,out,p)
    samples=out/'samples';samples.mkdir()
    def emit(path,raw):path.write_text(''.join('%02x\n'%v for v in raw))
    def tensor(sample,key,shape):
        s=sample['tensors'][key]
        if s['shape']!=shape or s['binary_dtype'] not in ('|i1','|u1'):raise ValueError('tensor format: '+key)
        return read(root/s['file'],s['sha256'],s['bytes'])
    for i,sample in enumerate(m['samples']):
        if sample['index']!=i:raise ValueError('missing/duplicate sample')
        sin=tensor(sample,'input_int',[99,64]);sout=tensor(sample,'output',[99,64])
        emit(samples/('s%02d_sample_input.hex'%i),sin);emit(samples/('s%02d_sample_output.hex'%i),sout)
        prev=sin
        for name in NAMES:
            parts=[];width=99 if name in ('score','softmax') else 256 if name in ('fc1','gelu') else 64
            for b in m['blocks']:parts.append(tensor(sample,b+'.'+name,[99,width]))
            emit(samples/('s%02d_%s.hex'%(i,name)),b''.join(parts))
        for b in m['blocks']:
            current=tensor(sample,b+'.input',[99,64]);result=tensor(sample,b+'.output',[99,64])
            if current!=prev:raise ValueError('broken layer chain')
            prev=result
        if prev!=sout:raise ValueError('final tensor inconsistent')
    for path in out.rglob('*'):
        if path.is_file():outputs[str(path)]={'sha256':sha(path),'bytes':path.stat().st_size}
    manifest={'golden_root':str(root),'candidate':m['candidate'],'samples':24,'layers':12,'inputs':inputs,'outputs':outputs,
              'packer_verify':{'words':n,'values':c},'independent_v3_decode':dec,'numpy_version':np.__version__}
    (out/'data_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('KSE_DATA_PREPARED',json.dumps({k:v for k,v in manifest.items() if k not in ('inputs','outputs')}))


if __name__=='__main__':main()
