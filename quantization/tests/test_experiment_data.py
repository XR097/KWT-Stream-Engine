import io
import wave

import numpy as np
import pytest

from quantization.experiment_data import (_check_leakage, _decode_pcm,
                                          _pcm_fingerprint, _record,
                                          _select_per_class, _speaker)


def test_exact_pcm_padding_identity():
    values = np.asarray([-32768, -1, 0, 32767], dtype="<i2")
    output = io.BytesIO()
    with wave.open(output, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(values.tobytes())
    padded = np.zeros(16000, dtype=np.float32)
    padded[:4] = values.astype(np.float32) / 32768
    assert _decode_pcm(output.getvalue()) == _pcm_fingerprint(padded)


def test_pcm_rejects_approximate_or_nonfinite_samples():
    data = np.zeros(16000, dtype=np.float32)
    data[1] = 0.123456
    with pytest.raises(ValueError, match="exact signed PCM16"):
        _pcm_fingerprint(data)
    data[1] = np.nan
    with pytest.raises(ValueError, match="finite"):
        _pcm_fingerprint(data)


def test_fixed_per_class_selection_order():
    labels = np.tile(np.arange(12), 11)
    indices = _select_per_class(labels, 10)
    assert len(indices) == 120
    assert indices[:10] == list(range(0, 120, 12))
    assert np.bincount(labels[indices], minlength=12).tolist() == [10] * 12
    with pytest.raises(ValueError, match="class"):
        _select_per_class(np.arange(11), 1)


def test_speaker_and_silence_policy():
    assert _speaker("yes/abc123_nohash_4.wav") == "abc123"
    silence = _record(0, 0, [{"relative_path": "yes/source.wav"}])
    assert silence["silence"] and not silence["source_candidates"]
    assert _check_leakage({"train": [silence], "test": [silence]})["status"] == "passed"


def test_leakage_includes_all_ambiguous_candidates():
    first = {"relative_path": "yes/a_nohash_0.wav", "sha256": "one", "speaker": "a"}
    second = {"relative_path": "no/a_nohash_1.wav", "sha256": "two", "speaker": "a"}
    records = {"train": [_record(0, 2, [first])], "test": [_record(0, 3, [second])]}
    audit = _check_leakage(records)
    assert audit["status"] == "failed"
    pair = audit["pairs"]["test__train"]
    assert pair["speaker"]["overlap_count"] == 1
    assert pair["relative_path"]["overlap_count"] == 0
