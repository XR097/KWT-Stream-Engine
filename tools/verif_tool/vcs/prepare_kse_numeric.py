#!/usr/bin/env python3
"""Integer-only numerical vectors: divmod RNE, math.isqrt, frozen ROM bytes."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import random
import struct

REPO=Path(__file__).resolve().parents[3]


def rne(x,s):
    if s<=0:return x*(1<<-s)
    q,r=divmod(abs(x),1<<s)
    q+=2*r>(1<<s) or (2*r==(1<<s) and q%2==1)
    return -q if x<0 else q


def sat(x):return max(-128,min(127,x))


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--golden',type=Path,default=REPO/'kwt-data/golden/9498911f415c30adccc1_middle')
    a=ap.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=False);root=a.golden.resolve()
    p=json.loads((root/'profile/profile.json').read_text());rng=random.Random(20261110);inputs={}
    def array(key,code):
        spec=p['arrays'][key];path=root/'profile'/spec['binary'];raw=path.read_bytes();h=hashlib.sha256(raw).hexdigest()
        if h!=spec['binary_sha256']:raise ValueError('ROM source changed')
        inputs[str(path)]=h
        return struct.unpack('<'+code*(len(raw)//struct.calcsize(code)),raw)
    exp=array('softmax.exp_q15_compact','H')
    cfg=[]
    for b in p['blocks']:
        g=p['gelu_configs'][b+'.gelu'];cfg.append((g['minimum_input'],g['maximum_input'],g['output_exponent']-g['input_exponent'],array(g['table_key'],'b')))
    def gelu(x,l):
        lo,hi,tail,table=cfg[l]
        return 0 if x<lo else sat(rne(x,tail)) if x>hi else table[x-lo]
    counts=Counter();vectors=[];bins=Counter()
    def emit(op,a=0,b=0,c=0,d=0,e=0,f=0,y=0,z=0):
        vectors.append(' '.join('%016x'%(int(v)&((1<<64)-1)) for v in (op,a,b,c,d,e,f,y,z))+'\n');counts[op]+=1
    xs=[-(1<<24),-(1<<24)+1,-257,-256,-255,-129,-128,-127,-7,-5,-3,-2,-1,0,1,2,3,5,7,126,127,128,129,255,256,257,(1<<24)-2,(1<<24)-1]
    for x in xs:
        for s in list(range(-7,33))+[63,127]:emit(0,x&0x1ffffff,s&255,y=rne(x,s)&0xffffffff)
    for _ in range(4000):
        x=rng.randrange(-(1<<24),1<<24);s=rng.randrange(-7,34);emit(0,x&0x1ffffff,s&255,y=rne(x,s)&0xffffffff)
    for x in list(range(-260,261))+[-(1<<31),(1<<31)-1]+[rng.randrange(-(1<<31),1<<31) for _ in range(1000)]:emit(1,x&0xffffffff,y=sat(x)&255)
    for op,nw,dw,qw in [(2,23,22,8),(3,38,24,30)]:
        pairs=[]
        for den in [0,1,2,3,4,7,16,257,(1<<dw)-1]:
            for q in [0,1,2,3,(1<<qw)-2,(1<<qw)-1,1<<qw]:
                for r in sorted(set([0,den//2,max(0,den//2-1),min(max(0,den-1),den//2+1),max(0,den-1)])):
                    if q*den+r<(1<<nw):pairs.append((q*den+r,den))
        pairs += [(rng.randrange(1<<nw),rng.randrange(1<<dw)) for _ in range(3000)]
        for tag,(n,d) in enumerate(pairs):
            ovf=d==0 or n>=d*(1<<qw);q=0
            if not ovf:
                q,r=divmod(n,d);q+=2*r>d or (2*r==d and q%2==1)
                if 2*r==d:bins['divider_tie_even' if (n//d)%2==0 else 'divider_tie_odd']+=1
            bins['divider_overflow' if ovf else 'divider_defined']+=1
            emit(op,n,d,tag,y=q,z=int(ovf))
    roots=list(range(20))+[127,128,255,256,65535,65536,(1<<18)-1]
    nums={0,(1<<36)-1}
    for r in roots:
        for d in [-1,0,1]:
            if 0<=r*r+d<(1<<36):nums.add(r*r+d)
    nums.update(rng.randrange(1<<36) for _ in range(1500))
    for n in sorted(nums):emit(4,n,y=math.isqrt(n))
    for l in range(12):
        lo,hi,tail,_=cfg[l]
        for x in range(-128,128):emit(5,x&255,l,lo&255,hi&255,tail&255,y=gelu(x,l)&255)
    for i,v in enumerate(exp):emit(6,i,y=v)
    for sh in range(-15,1):
        for delta in range(256):
            q8=-delta*(1<<-sh);idx=rne(min(-q8,4096),4);v=0 if q8< -4096 else exp[idx]
            bins['exp_cutoff' if q8< -4096 else 'exp_defined']+=1
            emit(7,(127-delta)&255,127,sh&255,1,y=v)
        emit(7,0,0,sh&255,0,y=0)
    for i in range(4000):
        acc=rng.randrange(-(1<<23),1<<23) if i>=1000 else (i-500)*3
        bias=rng.randrange(-32768,32768) if i>=1000 else 0
        sh=rng.randrange(-7,25);l=i%12;enable=i%2;lo,hi,tail,_=cfg[l]
        pre=sat(rne(acc+bias,sh));y=gelu(pre,l) if enable else pre
        emit(8,acc&0xffffff,bias&65535,sh&255,enable,l,(lo&255)|((hi&255)<<8)|((tail&255)<<16),y=(pre&255)|((y&255)<<8))
    path=out/'numeric.txt';path.write_text(''.join(vectors))
    manifest={'oracle':'Python integer divmod round-half-even, math.isqrt floor, frozen profile binary ROM tables; no RTL execution',
              'generator_seed':20261110,'counts':dict(counts),'defined_bins':dict(bins),'vectors_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'inputs':inputs,
              'profile_sha256':hashlib.sha256((root/'profile/profile.json').read_bytes()).hexdigest()}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print('KSE_NUMERIC_DATA',json.dumps(manifest))


if __name__=='__main__':main()
