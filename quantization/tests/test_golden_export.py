"""KSE packed weights and logical operator manifests are checked."""
import copy
import hashlib
import json

import numpy as np
import pytest

from quantization.integer import IntegerEncoder, configure_profile
from quantization.tests.test_nonlinear import fixture_profile
from quantization.scripts.export_sim_golden import (CANDIDATE_ID, export_sim_golden,
    frozen_config, pack_weight_rows, unpack_weight_rows, verify_manifest, profile_identity)


def test_exact_frozen_configuration_identity():
    config = frozen_config()
    actual = hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:20]
    assert actual == CANDIDATE_ID
    assert len(config["weight_bits_by_linear"]) == 72
    config["gelu"] = "middle"
    assert profile_identity({"nonlinear": config}) == ("9498911f415c30adccc1", "9498911f415c30adccc1_middle")


@pytest.mark.parametrize("fraction,dtype", [(7,"|u1"),(8,"|u1"),(11,"<u2")])
def test_asic_probability_storage(tmp_path,fraction,dtype):
    p,a,w=fixture_profile()
    p,a=configure_profile(p,a,w,{"accumulator_bits":24,"residual_accumulator_bits":24,
        "gelu":"middle","weight_bits_by_linear":{"b00.q":4},
        "softmax":{"table":"compact","exp_frac":15,"prob_frac":fraction},
        "layernorm":{"method":"reference","norm_frac":12,"gamma_frac":12}})
    w["head.weight"]=np.zeros((64,12),dtype=np.float32); w["head.bias"]=np.arange(12,dtype=np.float32)
    encoder=IntegerEncoder(p,a)
    samples=np.random.RandomState(3).normal(0,1,(1,99,64)).astype(np.float32)
    manifest=export_sim_golden(tmp_path,samples,encoder,w,[0])
    assert manifest["samples"][0]["tensors"]["b00.softmax"]["dtype"] == dtype
    assert verify_manifest(tmp_path)["samples"] == 1


def test_weight_rows_transposes_and_pairs_along_input():
    weights = np.array([[-8, 3], [-1, 4], [0, 5], [7, 6]], np.int8)
    packed = pack_weight_rows(weights)
    np.testing.assert_array_equal(packed, [0xF8, 0x70, 0x43, 0x65])
    np.testing.assert_array_equal(unpack_weight_rows(packed, (2, 4)), weights.T)


def test_weight_rows_odd_input_pads_each_output_row():
    weights = np.array([[-8, 3], [-1, 4], [7, -2]], np.int8)
    packed = pack_weight_rows(weights)
    np.testing.assert_array_equal(packed, [0xF8, 0x07, 0x43, 0x0E])
    np.testing.assert_array_equal(unpack_weight_rows(packed, (2, 3)), weights.T)
    packed[1] |= 0x10
    with pytest.raises(ValueError, match="odd tail"):
        unpack_weight_rows(packed, (2, 3))


@pytest.mark.parametrize("gelu_method", ["direct", "middle"])
def test_golden_manifest_complete_and_checksums_checked(tmp_path, gelu_method):
    p, a, w = fixture_profile()
    config = frozen_config()
    config["gelu"] = gelu_method
    config["weight_bits_by_linear"] = {k: 4 for k in p["linears"]}
    p, a = configure_profile(p, a, w, config)
    w["head.weight"] = np.asfortranarray(np.random.RandomState(71).normal(0, .001, (64, 12)).astype(np.float32))
    w["head.bias"] = np.arange(12, dtype=np.float32)
    samples = np.random.RandomState(3).normal(0, 1, (1, 99, 64)).astype(np.float32)
    manifest = export_sim_golden(tmp_path, samples, IntegerEncoder(p, a), w, [17])
    assert manifest["status"] == "verified"
    tensors = manifest["samples"][0]["tensors"]
    assert tensors["b00.ln2"]["file"] == tensors["b00.output"]["file"]
    assert tensors["b00.score"]["shape"] == [99, 99]
    assert tensors["b00.score.matmul"]["dtype"] == "<i4"
    assert tensors["b00.context.matmul"]["shape"] == [99, 64]
    assert tensors["b00.softmax"]["dtype"] == "|u1"
    assert tensors["logits"]["shape"] == [12]
    assert manifest["samples"][0]["source_index"] == 17
    assert manifest["samples"][0]["prediction"] == 11
    parameters = manifest["parameters"]["tensors"]
    assert parameters["b00.q.weight"]["axes"] == ["output", "input"]
    assert parameters["b00.q.shift"]["dtype"] == "<i4"
    exp_table = parameters[p["softmax_configs"]["b00"]["table_key"]]
    assert exp_table["dtype"] == "<i4"
    assert exp_table["bytes"] == 257 * 4
    assert verify_manifest(tmp_path)["samples"] == 1
    broken = copy.deepcopy(manifest)
    del broken["samples"][0]["tensors"]["b00.ln1"]
    with pytest.raises(ValueError, match="missing operator"):
        verify_manifest(tmp_path, broken)
    binary = tmp_path / tensors["b00.q"]["file"]
    data = bytearray(binary.read_bytes())
    data[0] ^= 1
    binary.write_bytes(data)
    with pytest.raises(ValueError, match="SHA256 mismatch"):
        verify_manifest(tmp_path)
