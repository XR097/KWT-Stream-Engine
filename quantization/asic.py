"""Fresh, reproducible ASIC measurements; test records cannot enter selection."""
import hashlib
import json
import math
import os
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
import numpy as np
from .export import load_profile, export_operator_vectors
from .integer import IntegerEncoder, configure_profile, quantize, dequantize, signed_bits
from .reference import load_reference, classify_float
from .experiments import config_id, _merge_ranges
from .pipeline import _merge_max, _merge_saturation, _file_hash

OPS = ("q", "k", "v", "proj", "fc1", "fc2")
MATRICES = tuple("b%02d.%s" % (i, op) for i in range(12) for op in OPS)
BASE_WORDS = 83904
STAGES = ("baseline", "single", "greedy", "structure", "nonlinear", "final", "stats", "golden", "report")
W = {}


def write_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def select_per_class(labels, count):
    indices = np.concatenate([np.flatnonzero(labels == c)[:count] for c in range(12)])
    if len(indices) != 12 * count: raise ValueError("not enough samples per class")
    return indices


def config(w8=(), probability=7, norm=12, gamma=12, gelu="middle"):
    return {"gelu": gelu, "accumulator_bits": 24, "residual_accumulator_bits": 24,
            "weight_bits_by_linear": {k: 8 if k in w8 else 4 for k in MATRICES},
            "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": probability},
            "layernorm": {"method": "reference", "norm_frac": norm, "gamma_frac": gamma}}


def cost(c):
    extra = sum(2048 if k.endswith(("fc1", "fc2")) else 512 for k,v in c["weight_bits_by_linear"].items() if v == 8)
    return {"w8": sorted(k for k,v in c["weight_bits_by_linear"].items() if v == 8), "extra_words": extra,
            "total_words": BASE_WORDS + extra, "extra_percent": extra / BASE_WORDS * 100}


def annotate(r):
    if r["split"] != "validation_full": raise ValueError("test records cannot be scored or selected")
    r = dict(r, **cost(r["config"]))
    r["accuracy_score"] = min(10., 10. - r["drop_pp"] / .2)
    r["J"] = r["accuracy_score"] - .2 * r["extra_percent"]
    r["max_ln_quotient_bits"] = max([v["required_signed_bits"] for k,v in r.get("ranges",{}).items() if k.endswith(".normalization_quotient")] or [0])
    r["max_mac_bits"] = max(r.get("mac_required_bits",{}).values() or [0])
    r["eligible"] = bool(r["status"] == "complete" and not r["overflow_count"] and r["max_mac_bits"] <= 24 and
                         r["max_ln_quotient_bits"] <= 17 and r["config"]["softmax"]["prob_frac"] <= 8)
    return r


def choose_roles(results):
    if any(r.get("split")!="validation_full" for r in results):
        raise ValueError("recommendations require validation records only")
    pool = list({r["config_id"]:r for r in results if r.get("eligible")}.values())
    if not pool: raise ValueError("no validation candidate satisfies hardware constraints")
    by_j = lambda r: (-r["J"], -r["correct"], r["extra_words"], r["config_id"])
    return {"J_best": min(pool,key=by_j), "under_5pct": min([r for r in pool if r["extra_percent"] <= 5],key=by_j),
            "highest_accuracy": min(pool,key=lambda r:(-r["correct"],-r["J"],r["extra_words"],r["config_id"]))}


def bootstrap(fp_prediction, prediction, labels, seed=20261108, draws=10000):
    delta = (np.asarray(fp_prediction)==labels).astype(np.int8)-(np.asarray(prediction)==labels).astype(np.int8)
    rng = np.random.RandomState(seed)
    values = np.concatenate([rng.choice(delta,(min(100,draws-i),600),replace=True).mean(1)*100 for i in range(0,draws,100)])
    return {"seed":seed,"draws":draws,"sample_size":600,"paired":True,"mean_pp":float(values.mean()),
            "std_pp":float(values.std(ddof=1)),"p05_pp":float(np.percentile(values,5)),"p50_pp":float(np.percentile(values,50)),
            "p95_pp":float(np.percentile(values,95)),"prob_gt_2pp":float(np.mean(values>2.))}


def prepare(args,folder):
    """Fresh TF logits/boundaries on sorted official full partitions, in batches."""
    cache=folder/"cache"; marker=cache/"preparation.json"
    upstream_root=Path(args.reference_root or args.repo_root).resolve()
    upstream=upstream_root/"third-party"/"kwt"
    checkpoint=upstream/"models_data_v2_12_labels"/"kwt1"
    source={"reference_py":_file_hash(Path(args.repo_root)/"quantization/reference.py"),
            "upstream":{str(p.relative_to(upstream)):_file_hash(p) for p in sorted(upstream.rglob("*.py"))},
            "checkpoint":{p.name:_file_hash(p) for p in sorted(checkpoint.iterdir()) if p.is_file()}}
    if marker.exists():
        saved=read_json(marker)
        if saved["source"]!=source: raise ValueError("reference/checkpoint changed; preparation cannot resume")
        for name,digest in saved["files"].items():
            if _file_hash(cache/name)!=digest: raise ValueError("prepared cache changed: "+name)
        return saved
    cache.mkdir(parents=True,exist_ok=True)
    ref=load_reference(upstream_root)
    try:
        weights=ref.weights()
        old_path=Path(args.data_root)/"experiments/w4w8_nonlinear_v1/cache/weights.npz"
        with np.load(old_path) as old:
            if set(old.files)!=set(weights) or any(not np.array_equal(weights[k],old[k]) for k in weights):
                raise ValueError("checkpoint weights differ from calibration checkpoint")
        np.savez(cache/"weights.npz",**weights)
        processor=ref.build_processor(Path(args.data_root)/"data2")
        comparisons,fp32,partition_sources={},{},{}
        for split,mode,count in (("validation_full","validation",4445),("testing","testing",4890)):
            if processor.set_size(mode)!=count: raise ValueError("unexpected official partition size: "+mode)
            records=[]
            for item in processor.data_index[mode]:
                path=Path(item["file"])
                records.append({"file":str(path.relative_to(Path(args.data_root)/"data2")),"label":item["label"],"sha256":_file_hash(path)})
            manifest={"mode":mode,"count":count,"source":source,"records":records,"glob_policy":"sorted before seeded official shuffle"}
            order_path=cache/(split+"_sources.json")
            if order_path.exists() and read_json(order_path)!=manifest: raise ValueError("official partition order changed")
            write_json(order_path,manifest)
            chunk_dir=cache/(split+"_batches"); chunk_dir.mkdir(exist_ok=True)
            values={k:[] for k in ("boundary","labels","float_logits","wave_hash")}
            for start in range(0,count,32):
                part=chunk_dir/("%05d.npz"%start)
                if not part.exists():
                    waves,labels=ref.get_batch(processor,mode,start,min(32,count-start))
                    boundary,logits=ref.boundary_and_logits(waves)
                    hashes=np.asarray([hashlib.sha256(w.astype("<f4").tobytes()).hexdigest() for w in waves])
                    tmp=part.with_suffix(".tmp")
                    with tmp.open("wb") as f: np.savez_compressed(f,boundary=boundary,labels=labels,float_logits=logits,wave_hash=hashes)
                    tmp.replace(part)
                with np.load(part) as z:
                    for k in values: values[k].append(z[k])
                if start%256==0 or start+32>=count: print("prepare %s %d/%d"%(split,min(start+32,count),count),flush=True)
            data={k:np.concatenate(v) for k,v in values.items()}
            np.savez(cache/(split+".npz"),**data)
            legacy=(Path(args.data_root)/"experiments/w4w8_nonlinear_v1/cache/validation_full.npz" if mode=="validation" else Path(args.data_root)/"cache/testing.npz")
            with np.load(legacy) as old:
                comparisons[split]={"old_cache":str(legacy),"old_sha256":_file_hash(legacy),"label_mismatches":int(np.sum(old["labels"]!=data["labels"])),
                                     "boundary_rows_identical":int(np.sum(np.all(old["boundary"]==data["boundary"],axis=(1,2)))),
                                     "old_top1":float(np.mean(np.argmax(old["float_logits"],1)==old["labels"]))}
            pred=np.argmax(data["float_logits"],1)
            fp32[split]={"count":count,"correct":int(np.sum(pred==data["labels"])),"top1":float(np.mean(pred==data["labels"])),"predictions":pred.tolist()}
            partition_sources[split]=_file_hash(order_path)
        with np.load(cache/"testing.npz") as z:
            idx=select_per_class(z["labels"],50); pred=np.asarray(fp32["testing"]["predictions"])
            fp32["check600"]={"count":600,"correct":int(np.sum(pred[idx]==z["labels"][idx])),"top1":float(np.mean(pred[idx]==z["labels"][idx]))}
        with np.load(cache/"validation_full.npz") as z: gp=select_per_class(z["labels"],2)
        selection={"policy":"first 50/test and first 2/validation per class; labels only; remapped to deterministic new order","check600":idx.tolist(),"golden24":gp.tolist()}
        write_json(cache/"selections.json",selection)
        saved={"source":source,"restoration":ref.restoration,"files":{p.name:_file_hash(p) for p in cache.glob("*.npz")},
               "partition_sources":partition_sources,"cache_comparison":comparisons,"fp32":fp32,"selections":selection,"status":"fresh_official_reference_complete"}
        write_json(marker,saved); return saved
    finally: ref.close()


def init_worker(folder,root,identity):
    global W
    folder,root=Path(folder),Path(root)
    p,a=load_profile(root/"profiles/W8A8_integer")
    with np.load(folder/"cache/weights.npz") as z: weights={k:z[k] for k in z.files}
    data={}
    for split in ("validation_full","testing"):
        with np.load(folder/"cache"/(split+".npz")) as z: data[split]={k:z[k] for k in ("labels","float_logits")}
        data[split]["boundary"]=np.load(folder/"cache"/(split+"_boundary.npy"),mmap_mode="r")
    W={"folder":folder,"base":(p,a),"weights":weights,"identity":identity,"data":data}


def evaluate_job(c,split,start=0,prefix_build=False):
    folder=W["folder"]
    ident=config_id({"config":c,"split":split,"start":start,"identity":W["identity"]})
    result_path=folder/"results"/(ident+".json"); progress_path=folder/"progress"/(ident+".json")
    if result_path.exists(): return read_json(result_path)
    p,a=configure_profile(*W["base"],W["weights"],c)
    enc=IntegerEncoder(p,a); enc.params=dict(p,blocks=p["blocks"][start:])
    data=W["data"][split]; n=len(data["labels"])
    state={"next":0,"predictions":[],"seconds":0.,"mac_required_bits":{},"wide_required_bits":{},"ranges":{},"saturation":{},"output_hashes":[]}
    if progress_path.exists(): state=read_json(progress_path)
    prefix={}
    if start: prefix["read"]=np.load(folder/"cache"/("prefix_b%02d.npy"%start),mmap_mode="r")
    if prefix_build:
        for b in p["blocks"]:
            path=folder/"cache"/("prefix_"+b+".npy")
            prefix[b]=np.lib.format.open_memmap(path,mode="r+" if path.exists() else "w+",dtype=np.int8,shape=(n,99,64))
    for begin in range(state["next"],n,8):
        end=min(n,begin+8)
        q=prefix["read"][begin:end].astype(np.int64) if start else quantize(data["boundary"][begin:end],p["exponents"]["b00.input"],8)
        tick=time.perf_counter(); out,traces=enc.run(q,trace=prefix_build)
        logits=classify_float(W["weights"],dequantize(out,p["exponents"]["b11.output"]))
        if not np.all(np.isfinite(logits)): raise ArithmeticError("nonfinite logits")
        state["seconds"]+=time.perf_counter()-tick
        if prefix_build:
            for b in p["blocks"]: prefix[b][begin:end]=traces[b+".input"]; prefix[b].flush()
        _merge_max(state["mac_required_bits"],enc.last_mac_required_bits)
        _merge_max(state["wide_required_bits"],enc.last_wide_required_bits)
        _merge_saturation(state["saturation"],enc.last_saturation)
        _merge_ranges(state["ranges"],{k:v for k,v in enc.last_stats.items() if k.endswith((".prefix",".bias",".shift_codes",".normalization_quotient",".affine_product",".softmax")) and "saturated" not in v})
        state["predictions"].extend(np.argmax(logits,1).tolist()); state["output_hashes"].append(hashlib.sha256(out.astype("<i8").tobytes()).hexdigest())
        state["next"]=end; write_json(progress_path,state)
    labels=data["labels"]; fp_top1=float(np.mean(np.argmax(data["float_logits"],1)==labels)); correct=int(np.sum(np.asarray(state["predictions"])==labels))
    r=dict(state,id=ident,config_id=config_id(c),config=c,split=split,count=n,status="complete",correct=correct,top1=correct/n,float_top1=fp_top1,
           drop_pp=(fp_top1-correct/n)*100,start_block=start,overflow_count=0,finite_outputs=True,identity=W["identity"])
    if start:
        base=read_json(folder/"reports/baseline.json")["all_w4_q15_p7_ln12"]["validation_full"]
        for field in ("mac_required_bits","wide_required_bits","ranges","saturation"):
            for key,value in base[field].items():
                if int(key[1:3])<start: r[field][key]=value
    if split=="validation_full": r=annotate(r)
    else:
        idx=select_per_class(labels,50)
        r["check600"]={"count":600,"correct":int(np.sum(np.asarray(state["predictions"])[idx]==labels[idx])),"top1":float(np.mean(np.asarray(state["predictions"])[idx]==labels[idx]))}
    write_json(result_path,r); return r


class Study:
    def __init__(self,args,folder,preparation):
        self.args,self.folder,self.preparation=args,folder,preparation
        self.root=Path(args.data_root).resolve(); repo=Path(args.repo_root).resolve()
        sources={str(p.relative_to(repo)):_file_hash(p) for p in sorted((repo/"quantization").rglob("*")) if p.suffix in (".py",".c",".ps1")}
        profile=self.root/"profiles/W8A8_integer"
        self.identity={"experiment":"asic_numerics_v1","revision":"fresh_v2","sources":sources,"numpy":np.__version__,"data":preparation["files"],
                       "boundary_maps":{p.name:_file_hash(p) for p in sorted((folder/"cache").glob("*_boundary.npy"))},
                       "profile":{p.name:_file_hash(p) for p in sorted(profile.iterdir()) if p.is_file()},
                       "native_mac":_file_hash(os.environ["KWT_ASIC_MAC_LIBRARY"]) if os.environ.get("KWT_ASIC_MAC_LIBRARY") else None}
        for name in ("reports","results","progress","golden"): (folder/name).mkdir(parents=True,exist_ok=True)
        marker=folder/"run_identity.json"
        if marker.exists() and read_json(marker)!=self.identity: raise ValueError("frozen identity changed; cannot combine source versions")
        write_json(marker,self.identity)
        self.pool=ProcessPoolExecutor(max_workers=min(12,args.workers),initializer=init_worker,initargs=(str(folder),str(self.root),self.identity))

    def evaluate(self,configs,split="validation_full",suffix=False,prefix_build=False):
        unique={config_id(c):c for c in configs}; jobs={}
        for ident,c in unique.items():
            start=0
            if suffix and c["softmax"]==config()["softmax"] and c["layernorm"]==config()["layernorm"]:
                changed=cost(c)["w8"]; start=min(int(k[1:3]) for k in changed) if changed else 0
            jobs[self.pool.submit(evaluate_job,c,split,start,prefix_build)]=ident
        result={}
        for f in as_completed(jobs):
            r=f.result(); result[jobs[f]]=r
            print("%s %s %d top1=%.6f drop=%.6f J=%s maxMAC=%d seconds=%.1f"%(split,r["config_id"],r["count"],r["top1"]*100,r["drop_pp"],r.get("J"),max(r["mac_required_bits"].values()),r["seconds"]),flush=True)
        return [result[config_id(c)] for c in configs]

    def record(self,name,value): write_json(self.folder/"reports"/(name+".json"),value)
    def read(self,name): return read_json(self.folder/"reports"/(name+".json"))

    def baseline(self):
        values={"fp32":self.preparation["fp32"],"identity":self.identity}
        for name,c in (("all_w4_q15_p7_ln12",config()),("all_w8a8",config(MATRICES))):
            val=self.evaluate([c],prefix_build=name=="all_w4_q15_p7_ln12")[0]
            test=self.evaluate([c],"testing")[0]
            values[name]={"validation_full":val,"testing":test,"check600":test["check600"]}
            self.record("baseline",values)

    def single(self):
        base=self.read("baseline")["all_w4_q15_p7_ln12"]["validation_full"]
        results=self.evaluate([config([k]) for k in MATRICES],suffix=True)
        for r in results:
            r["matrix"]=r["w8"][0]; r["delta_acc_pp"]=(r["top1"]-base["top1"])*100
            r["gain_per_1000_words"]=r["delta_acc_pp"]/(r["extra_words"]/1000.)
        self.record("single",results)

    def greedy(self):
        base=self.read("baseline")["all_w4_q15_p7_ln12"]["validation_full"]
        ranked=sorted([r for r in self.read("single") if r["delta_acc_pp"]>0],key=lambda r:(-r["gain_per_1000_words"],-r["delta_acc_pp"],r["matrix"]))
        points=[base]; w8=[]; best=base["J"]; stale=0
        for item in ranked[:30]:
            w8.append(item["matrix"])
            if cost(config(w8))["extra_percent"]>40: break
            r=self.evaluate([config(w8)],suffix=True)[0]; points.append(r)
            stale=0 if r["J"]>best+1e-12 else stale+1; best=max(best,r["J"])
            self.record("greedy",{"points":points,"ranked":[r["matrix"] for r in ranked],"stop":"running"})
            if stale>=4: break
        self.record("greedy",{"points":points,"ranked":[r["matrix"] for r in ranked],"stop":"four consecutive J non-improvements" if stale>=4 else "positive-gain list / 30 points / 40% limit"})

    def structure(self):
        groups={"layer_%02d"%i:[k for k in MATRICES if k.startswith("b%02d."%i)] for i in range(12)}
        for name,ops in (("q+k",("q","k")),("v",("v",)),("proj",("proj",)),("fc1",("fc1",)),("fc2",("fc2",)),("all_attention",("q","k","v","proj")),("all_FFN",("fc1","fc2"))):
            groups[name]=[k for k in MATRICES if k.split(".")[1] in ops]
        results=self.evaluate([config(keys) for keys in groups.values()],suffix=True)
        base=self.read("baseline")["all_w4_q15_p7_ln12"]["validation_full"]
        named=[dict(r,structure=name) for name,r in zip(groups,results)]; positive=[r for r in named if r["J"]>base["J"]]
        unions={}
        for kind,pool in (("positive_layers",[r for r in positive if r["structure"].startswith("layer_")]),("positive_types",[r for r in positive if not r["structure"].startswith("layer_")]),("positive_all",positive)):
            keys=sorted(set(k for r in pool for k in r["w8"]))
            if keys: unions[kind]=config(keys)
        if unions: named.extend(dict(r,structure=n) for n,r in zip(unions,self.evaluate(list(unions.values()),suffix=True)))
        self.record("structure",named)

    def nonlinear(self):
        baseline=self.read("baseline")
        pool=[baseline["all_w4_q15_p7_ln12"]["validation_full"],baseline["all_w8a8"]["validation_full"]]+self.read("single")+self.read("greedy")["points"]+self.read("structure")
        roles=choose_roles(pool); unique={r["config_id"]:r for r in roles.values()}
        for r in sorted(pool,key=lambda r:(-r["J"],r["extra_words"],r["config_id"])):
            if len(unique)>=3: break
            if r["eligible"]: unique.setdefault(r["config_id"],r)
        self.record("nonlinear_representatives",{"roles":{k:r["config_id"] for k,r in roles.items()},"ids":list(unique),"selection_split":"validation_full"})
        configs=[]
        for r in unique.values():
            configs.extend([config(r["w8"],probability=p) for p in (7,8,11)])
            configs.extend([config(r["w8"],norm=n,gamma=g) for n,g in ((12,12),(16,16),(20,16),(16,12),(20,20))])
        results=list({r["config_id"]:r for r in self.evaluate(configs)}.values()); self.record("nonlinear",results)
        init_worker(str(self.folder),str(self.root),self.identity); gelu=[]
        pd,ad=configure_profile(*W["base"],W["weights"],config(gelu="direct"))
        pm,am=configure_profile(*W["base"],W["weights"],config(gelu="middle"))
        direct,middle=IntegerEncoder(pd,ad),IntegerEncoder(pm,am); x=np.arange(-128,128,dtype=np.int64)
        for b in pd["blocks"]:
            key=b+".gelu"
            a=direct.gelu(x,pd["exponents"][b+".fc1"],pd["exponents"][key],key)
            m=middle.gelu(x,pm["exponents"][b+".fc1"],pm["exponents"][key],key)
            gelu.append({"layer":b,"inputs":256,"mismatches":int(np.sum(a!=m)),"direct_entries":int(ad[pd["gelu_configs"][key]["table_key"]].size),"middle_entries":int(am[pm["gelu_configs"][key]["table_key"]].size)})
        if any(r["mismatches"] for r in gelu): raise AssertionError("GELU mappings differ")
        self.record("gelu",gelu)

    def final(self):
        baseline=self.read("baseline")
        pool=[baseline["all_w4_q15_p7_ln12"]["validation_full"],baseline["all_w8a8"]["validation_full"]]+self.read("single")+self.read("greedy")["points"]+self.read("structure")+self.read("nonlinear")
        roles=choose_roles(pool); selected={r["config_id"]:r for r in roles.values()}
        for r in sorted(pool,key=lambda r:(-r["J"],-r["correct"],r["extra_words"],r["config_id"])):
            if len(selected)>=3: break
            if r["eligible"]: selected.setdefault(r["config_id"],r)
        self.record("frozen_recommendations",{"selection_split":"validation_full","test_used_for_selection":False,"identity":self.identity,
                                             "roles":{role:r["config_id"] for role,r in roles.items()},"recommended":list(selected.values())})
        curves=self.read("greedy")["points"]
        test=self.evaluate([r["config"] for r in list(selected.values())+curves],"testing"); by_id={r["config_id"]:r for r in test}
        with np.load(self.folder/"cache/testing.npz") as z: labels=z["labels"]
        fp=np.asarray(self.preparation["fp32"]["testing"]["predictions"]); recommendations=[]
        for r in selected.values():
            tr=by_id[r["config_id"]]
            if tr["drop_pp"]>=2: raise AssertionError("validation-selected recommendation fails test gate")
            if max(tr["mac_required_bits"].values())>24 or any(v["required_signed_bits"]>17 for k,v in tr["ranges"].items() if k.endswith(".normalization_quotient")):
                raise AssertionError("validation-selected recommendation exceeds test hardware width")
            recommendations.append({"validation":r,"testing":tr,"check600":tr["check600"],"bootstrap":bootstrap(fp,tr["predictions"],labels)})
        self.record("final",{"roles":{role:r["config_id"] for role,r in roles.items()},"recommendations":recommendations,
                             "pareto":[{"validation":r,"testing":by_id[r["config_id"]]} for r in curves]})

    def stats(self):
        init_worker(str(self.folder),str(self.root),self.identity)
        p,a=configure_profile(*W["base"],W["weights"],config()); matrices=[]; layers=[]
        def entropy(c):
            probs=c[c>0]/float(c.sum()); return float(-np.sum(probs*np.log2(probs)))
        for key in MATRICES:
            weight=a[key+".weight"]; counts=np.bincount(weight.reshape(-1)+8,minlength=16); ent=entropy(counts)
            block=[entropy(np.bincount(v+8,minlength=16)) for v in weight.reshape(-1,64)]
            bias=a[key+".bias"]; spec=p["linears"][key]
            shifts=p["exponents"][spec["output"]]-p["exponents"][spec["input"]]-a[key+".weight_exponents"]
            matrices.append({"matrix":key,"bias_min":int(bias.min()),"bias_max":int(bias.max()),"bias_bits":signed_bits(bias),"bias_count":int(bias.size),
                             "shift_min":int(shifts.min()),"shift_max":int(shifts.max()),"shift_bits":signed_bits(shifts),"histogram_minus8_to7":counts.tolist(),
                             "elements":int(weight.size),"entropy_bits":ent,"block64_entropy_mean":float(np.mean(block)),"block64_entropy_min":float(np.min(block)),"block64_entropy_max":float(np.max(block)),
                             "ideal_saved_words_matrix":int(weight.size)*max(0,4-ent)/32,"ideal_saved_words_block64":int(weight.size)*max(0,4-float(np.mean(block)))/32})
        for b in p["blocks"]:
            entries=[r for r in matrices if r["matrix"].startswith(b+".")]
            weights=sum(a[r["matrix"]+".weight"].size//2 for r in entries)
            biases=sum(math.ceil(r["bias_count"]*r["bias_bits"]/8) for r in entries)
            shifts=sum(math.ceil(r["bias_count"]*r["shift_bits"]/8) for r in entries)
            normkeys=[k for k in a if k.startswith(b+".") and k.endswith((".gamma",".beta"))]
            norms=sum(math.ceil(a[k].size*signed_bits(a[k])/8) for k in normkeys)
            layers.append({"layer":b,"w4_bytes":weights,"bias_actual_width_bytes":biases,"shift_actual_width_bytes":shifts,"layernorm_actual_width_bytes":norms,
                           "other_bytes":shifts+norms,"parameter_bytes":weights+biases+shifts+norms})
        keys={s["table_key"] for cat in ("softmax_configs","gelu_configs") for s in p[cat].values()}
        lut={k:math.ceil(a[k].size*(max(1,int(a[k].max()).bit_length()) if a[k].min()>=0 else signed_bits(a[k]))/8) for k in keys}
        external={k:int(v.nbytes) for k,v in W["weights"].items() if k.startswith(("frontend.","head."))}
        self.record("stats",{"matrices":matrices,"layers":layers,"encoder_parameter_bytes":sum(r["parameter_bytes"] for r in layers),"shared_lut_bytes":sum(lut.values()),
                             "shared_luts":lut,"external_fp32_bytes":sum(external.values()),"external_fp32":external,
                             "total_model_bytes":sum(r["parameter_bytes"] for r in layers)+sum(lut.values())+sum(external.values()),
                             "scope":"tight bit streams; per-array byte rounding; shift codes replace weight exponents; LUT shared by key; metadata/alignment excluded",
                             "entropy_scope":"ideal zero-order payload estimates, not achieved compression; no codebook/header costs"})

    def golden(self):
        from .scripts.export_sim_golden import export_sim_golden,verify_manifest
        init_worker(str(self.folder),str(self.root),self.identity)
        indices=self.preparation["selections"]["golden24"]; samples=W["data"]["validation_full"]["boundary"][indices]; records=[]
        for row in self.read("final")["recommendations"]:
            r=row["validation"]; p,a=configure_profile(*W["base"],W["weights"],r["config"]); enc=IntegerEncoder(p,a)
            package=self.folder/"golden"/r["config_id"]
            if not (package/"sim_manifest.json").exists() or read_json(package/"sim_manifest.json").get("status")!="verified":
                export_sim_golden(package,samples,enc,W["weights"],indices,{"identity":self.identity,"source_split":"validation_full","indices":indices})
                export_operator_vectors(package/"operators",enc)
            manifest=verify_manifest(package)
            # The golden writer already checks reload/repeat/binary equality.
            # Keep package validation here; execution-backend replay is outside
            # the KSE quantization flow and cannot change exported numbers.
            if manifest["status"] != "verified" or manifest["samples"] != 24:
                raise AssertionError("golden package must contain 24 verified samples")
            records.append({"config_id":r["config_id"],"package":str(package),"manifest":manifest,
                            "operator_vectors":read_json(package/"operators/operator_manifest.json")["count"]})
            self.record("golden",records)

    def report(self):
        summary={"status":"complete","identity":self.identity,"preparation":self.preparation,"gelu":self.read("gelu"),
                 "nonlinear_representatives":self.read("nonlinear_representatives"),**{s:self.read(s) for s in STAGES if s!="report"}}
        write_json(self.folder.parent/"summary.json",summary)
        from .asic_report import render_report
        render_report(summary,Path(self.args.repo_root)/"docs/quantization/asic_numerics_report.md")


def run(args):
    if not 1<=args.workers<=12: raise ValueError("workers must be 1..12")
    folder=Path(args.data_root).resolve()/"experiments/asic_numerics_v1/measurements_v2"; folder.mkdir(parents=True,exist_ok=True)
    if (folder/"run_identity.json").exists() and not args.resume:
        raise ValueError("existing run requires --resume; refusing accidental overwrite")
    if args.stage=="prepare":
        prepare(args,folder)
        return
    if not (folder/"cache/preparation.json").exists():
        # Keep the TensorFlow graph out of the long-lived parallel NumPy parent.
        command=[sys.executable,"-B",str(Path(args.repo_root)/"quantization/scripts/run_asic_numerics.py"),"--stage","prepare",
                 "--data-root",args.data_root,"--repo-root",args.repo_root,"--workers",str(args.workers)]
        if args.reference_root: command.extend(["--reference-root",args.reference_root])
        if args.resume: command.append("--resume")
        subprocess.run(command,check=True)
    preparation=prepare(args,folder)
    for split in ("validation_full","testing"):
        path=folder/"cache"/(split+"_boundary.npy")
        if not path.exists():
            with np.load(folder/"cache"/(split+".npz")) as z:
                value=z["boundary"]
                tmp=path.with_suffix(".tmp")
                with tmp.open("wb") as f: np.save(f,value,allow_pickle=False)
                tmp.replace(path)
                del value
    study=Study(args,folder,preparation)
    try:
        for stage in STAGES if args.stage=="all" else (args.stage,):
            print("STAGE "+stage,flush=True)
            write_json(folder/"progress_status.json",{"stage":stage,"status":"running","time":time.time(),"identity":study.identity})
            getattr(study,stage)()
            write_json(folder/"progress_status.json",{"stage":stage,"status":"completed","time":time.time(),"identity":study.identity})
    finally: study.pool.shutdown(wait=True)
