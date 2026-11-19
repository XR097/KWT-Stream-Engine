import numpy as np

from quantization.integer import checked_matmul, build_profile, configure_profile, IntegerEncoder


def test_checked_24bit_prefix_and_overflow():
    a = np.array([[127, 127]], dtype=np.int64)
    b = np.array([[127], [127]], dtype=np.int64)
    np.testing.assert_array_equal(checked_matmul(a, b, bits=24), [[32258]])
    with np.testing.assert_raises(OverflowError):
        checked_matmul(np.full((1, 64), 2000, dtype=np.int64),
                       np.full((64, 1), 2000, dtype=np.int64), bits=24)


def test_p8_softmax_is_unsigned_byte_range():
    weights = {
        "b00.q.weight": np.zeros((64, 64), dtype=np.float64),
        "b00.k.weight": np.zeros((64, 64), dtype=np.float64),
        "b00.v.weight": np.zeros((64, 64), dtype=np.float64),
        "b00.proj.weight": np.zeros((64, 64), dtype=np.float64),
        "b00.fc1.weight": np.zeros((64, 256), dtype=np.float64),
        "b00.fc2.weight": np.zeros((256, 64), dtype=np.float64),
        "b00.ln1.gamma": np.ones(64), "b00.ln1.beta": np.zeros(64),
        "b00.ln2.gamma": np.ones(64), "b00.ln2.beta": np.zeros(64),
    }
    stats = {"b00." + n: {"max": 1.0} for n in
             ("input", "q", "k", "v", "score", "context", "proj", "res1",
              "ln1", "fc1", "gelu", "fc2", "res2", "output")}
    p, a = build_profile(weights, stats, 8, 8, accumulator_bits=24)
    p, a = configure_profile(p, a, weights, {
        "weight_bits_by_linear": {k: 4 for k in p["linears"]},
        "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": 8},
        "layernorm": {"norm_frac": 12, "gamma_frac": 12},
    })
    enc = IntegerEncoder(p, a)
    value = enc.softmax(np.zeros((2, 99), dtype=np.int64), -4, "b00.softmax")
    assert value.dtype.kind == "i" and int(value.max()) <= 255
    assert p["softmax_configs"]["b00"]["prob_frac"] == 8
    extreme = enc.softmax(np.array([[127,-128,-128]],dtype=np.int64),-2,"b00.softmax")
    np.testing.assert_array_equal(extreme,[[255,0,0]])
    sm = enc.last_stats["b00.softmax.softmax"]
    assert sm["stored_required_unsigned_bits"] == 8
    assert sm["quotient_required_unsigned_bits"] == 9


def test_prefix_width_is_not_final_width(monkeypatch):
    a=np.array([[7,7,-7,-7]],dtype=np.int64)
    b=np.ones((4,1),dtype=np.int64)
    for native in (False,True):
        if not native:
            monkeypatch.delenv("KWT_ASIC_MAC_LIBRARY",raising=False)
        stats={}
        np.testing.assert_array_equal(checked_matmul(a,b,bits=24,prefix_stats=stats),[[0]])
        assert stats == {"minimum":0,"maximum":14,"required_signed_bits":5}


def test_checked_24bit_cancelling_prefix_rejected():
    a=np.array([[1<<22,1<<22,-(1<<22)]],dtype=np.int64)
    with np.testing.assert_raises(OverflowError):
        checked_matmul(a,np.ones((3,1),dtype=np.int64),bits=24)


def test_native_matches_numpy_all_prefixes(monkeypatch):
    import os
    path=os.environ.get("KWT_ASIC_MAC_LIBRARY")
    if not path:
        import pytest
        pytest.skip("optional C accelerator not configured")
    rng=np.random.RandomState(43)
    for ashape,bshape in [((3,7),(7,5)),((2,3,7),(7,5)),((2,3,7),(2,7,5)),((3,7),(2,7,5))]:
        a=rng.randint(-128,128,ashape).astype(np.int64); b=rng.randint(-128,128,bshape).astype(np.int64)
        ns,ps={},{}
        monkeypatch.setenv("KWT_ASIC_MAC_LIBRARY",path)
        native=checked_matmul(a,b,24,prefix_stats=ns)
        monkeypatch.delenv("KWT_ASIC_MAC_LIBRARY")
        fallback=checked_matmul(a,b,24,prefix_stats=ps)
        np.testing.assert_array_equal(native,fallback)
        assert ns == ps


def test_cost_and_objective_use_brief_denominator():
    from quantization.asic import config,cost,annotate,MATRICES
    assert cost(config())["total_words"] == 83904
    assert cost(config(["b00.q"]))["extra_words"] == 512
    assert cost(config(["b00.fc2"]))["extra_words"] == 2048
    assert cost(config(MATRICES))["extra_words"] == 73728
    r=annotate({"config":config(["b00.q"]),"split":"validation_full","status":"complete","drop_pp":.6,"overflow_count":0})
    assert abs(r["J"]-(7-.2*512/83904*100)) < 1e-12
    with np.testing.assert_raises(ValueError): annotate(dict(r,split="testing"))


def test_bootstrap_is_paired_drop_not_error_rate():
    from quantization.asic import bootstrap
    labels=np.zeros(600,dtype=np.int64)
    wrong=np.ones(600,dtype=np.int64)
    same=bootstrap(wrong,wrong,labels,draws=100)
    assert same["mean_pp"] == 0 and same["prob_gt_2pp"] == 0
    improvement=bootstrap(wrong,labels,labels,draws=100)
    assert improvement["mean_pp"] == -100


def test_recommendation_roles_use_validation_and_width_limits():
    from quantization.asic import config,annotate,choose_roles
    def row(cid,drop,matrices=(),normbits=16):
        return annotate({"config_id":cid,"config":config(matrices),"split":"validation_full","status":"complete",
                         "drop_pp":drop,"correct":round(4445*(1-drop/100)),"overflow_count":0,
                         "mac_required_bits":{"b00.q.matmul":22},
                         "ranges":{"b00.ln1.normalization_quotient":{"required_signed_bits":normbits}}})
    base=row("base",.6)
    partial=row("partial",.5,["b00.q"])
    illegal=row("illegal",0,normbits=20)
    roles=choose_roles([base,partial,illegal])
    assert all(r["config_id"]=="partial" for r in roles.values())
    with np.testing.assert_raises(ValueError): choose_roles([dict(partial,split="testing")])
