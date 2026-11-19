"""Whole-run aggregation must include all batches and distinguish RMSE/NRMSE."""
import numpy as np
import pytest
from quantization.pipeline import _merge_errors, _final_errors, _merge_max, _merge_saturation, _stats, _TraceStats


def test_aggregation_keeps_early_batch_saturation_and_widths():
    counts, widths = {}, {}
    _merge_saturation(counts, {"b00.q": {"clipped": 2, "total": 128}})
    _merge_saturation(counts, {"b00.q": {"clipped": 0, "total": 32}})
    _merge_max(widths, {"b00.q.matmul": 23})
    _merge_max(widths, {"b00.q.matmul": 17})
    assert counts["b00.q"] == {"clipped": 2, "total": 160}
    assert widths["b00.q.matmul"] == 23


def test_errors_merge_with_reference_energy_normalization():
    errors = {}
    exponents = {"b00.output": -1}
    _merge_errors(errors, {"b00.output": np.array([2, 4])},
                  {"b00.output": np.array([2., 3.])}, exponents)
    _merge_errors(errors, {"b00.output": np.array([6])},
                  {"b00.output": np.array([3.])}, exponents)
    item = _final_errors(errors)["b00.output"]
    assert item["count"] == 3
    assert item["max_error"] == 1
    np.testing.assert_allclose(item["rmse"], np.sqrt(2 / 3))
    np.testing.assert_allclose(item["nrmse"], np.sqrt(2 / 22))


@pytest.mark.parametrize("samples,batch,width", [(97, 32, 64), (5, 2, 3), (1, 1, 1), (4890, 512, 7)])
def test_streamed_trace_stats_match_full_array(samples, batch, width):
    rng = np.random.RandomState(samples)
    traces = {"wide": rng.standard_normal((samples, 3, width)).astype(np.float32),
              "ties": rng.randint(-3, 4, (samples, width)).astype(np.float32),
              "empty": np.zeros((samples, 0), np.float32)}
    stats = _TraceStats(samples)
    for offset in range(0, samples, batch):
        part = {k: v[offset:offset + batch] for k, v in traces.items()}
        stats.add(part, len(part["wide"]))
    assert stats.result() == _stats(traces)


def test_streamed_trace_stats_reject_missing_batches():
    stats = _TraceStats(4)
    stats.add({"x": np.ones((2, 3), np.float32)}, 2)
    with pytest.raises(ValueError):
        stats.result()
