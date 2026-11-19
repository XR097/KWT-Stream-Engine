import sys
import json
from pathlib import Path

import numpy as np
import pytest

from quantization.scripts.verify_softmax_row_stream import partial_mac
from quantization.scripts.report_attention_dataflow import budget
from quantization.scripts.run_global_w4_modes import load_full_w4, make_config


def test_partial_sums_match_exact_matmul():
    rng = np.random.RandomState(7)
    for m, k, n in ((1,64,99),(8,64,99),(8,99,64)):
        a = rng.randint(-128,128,(m,k)).astype(np.int64)
        b = rng.randint(-128,128,(k,n)).astype(np.int64)
        actual = partial_mac(a,b,{},"test")
        assert actual.dtype == np.int32
        np.testing.assert_array_equal(actual, a@b)


def test_partial_overflow_cannot_be_hidden_by_later_cancellation():
    a = np.array([[2**30,2**30,-2**30]],dtype=np.int64)
    b = np.ones((3,1),dtype=np.int64)
    assert (a@b)[0,0] == 2**30
    with pytest.raises(OverflowError):
        partial_mac(a,b,{},"partial")


def test_int32_negative_endpoint_and_positive_overflow():
    stats = {}
    np.testing.assert_array_equal(partial_mac(np.array([[-2**31]]),np.array([[1]]),stats,"edge"), [[-2**31]])
    assert stats["edge"]["required_bits"] == 32
    with pytest.raises(OverflowError):
        partial_mac(np.array([[2**31]]),np.array([[1]]),{},"edge")


def test_traffic_includes_int32_scratch_and_full_w4_weights():
    report=budget()
    assert report["minimum_kv_resident_bytes"]==12672
    assert report["all_w4_weight_bytes_encoder"]==294912
    one=next(r for r in report["rows"] if r["query_tile_rows"]==1 and r["probability_bits"]==8)
    eight=next(r for r in report["rows"] if r["query_tile_rows"]==8 and r["probability_bits"]==8)
    assert one["kv_offchip_bytes_per_block_without_retention"]==1254528
    assert eight["kv_offchip_bytes_per_block_without_retention"]==164736
    assert eight["scratch_buffers_logical_bytes"]["pv_int32_accumulators"]==2048
    assert eight["scratch_buffers_logical_bytes"]["qk_int32_accumulators"]==3168


def test_global_config_has_no_unintended_layer_overrides():
    weight_map={"b00.q":4}
    cfg=make_config(weight_map,7,12)
    assert "softmax_by_block" not in cfg
    assert "layernorm_by_op" not in cfg
    assert cfg["residual_accumulator_bits"]==32
    assert cfg["weight_bits_by_linear"]==weight_map
    assert cfg["weight_bits_by_linear"] is not weight_map


def test_full_w4_source_returns_only_weight_map(tmp_path):
    bits={"m%d" % i:4 for i in range(72)}
    source=tmp_path/"acceptance.json"
    source.write_text(json.dumps({"results":[{"config":{"gelu":"direct","weight_bits_by_linear":bits}}]}))
    assert load_full_w4(source)==bits
    source.write_text(json.dumps({"results":[{"config":{"weight_bits_by_linear":{"m0":4}}}]}))
    with pytest.raises(RuntimeError):
        load_full_w4(source)
