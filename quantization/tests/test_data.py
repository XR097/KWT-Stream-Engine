import hashlib
import io
import tarfile
import wave

import numpy as np

from quantization import data


def _wav_bytes():
    output = io.BytesIO()
    with wave.open(output, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(np.zeros(160, dtype="<i2").tobytes())
    return output.getvalue()


def test_default_data_root_is_repository_local():
    root = data.default_data_root("/tmp/checkout/kse")
    assert root.parts[-1] == "kwt-data"


def test_prepare_dataset_extracts_and_writes_marker_without_network(tmp_path, monkeypatch):
    payload = _wav_bytes()
    archive = tmp_path / data.ARCHIVE_NAME
    with tarfile.open(archive, "w:gz") as handle:
        info = tarfile.TarInfo("speech_commands_v0.02/yes/example.wav")
        info.size = len(payload)
        handle.addfile(info, io.BytesIO(payload))

    monkeypatch.setattr(data, "DATASET_SIZE", archive.stat().st_size)
    monkeypatch.setattr(data, "DATASET_SHA256", hashlib.sha256(archive.read_bytes()).hexdigest())
    result = data.prepare_dataset(tmp_path, download=False, extract=True, min_free_gib=0)

    assert result["wav_count"] == 1
    assert (tmp_path / "data2" / "speech_commands_v0.02" / "yes" / "example.wav").is_file()
    assert (tmp_path / data.MARKER_NAME).is_file()
