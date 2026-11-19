"""Speech Commands V2 preparation helpers.

The module deliberately has no TensorFlow dependency.  It prepares the external
dataset used by the quantization experiments and records enough metadata to
resume safely after an interrupted download or extraction.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, Union


DATASET_URL = "https://storage.googleapis.com/download.tensorflow.org/data/speech_commands_v0.02.tar.gz"
DATASET_SIZE = 2_428_923_189
DATASET_SHA256 = "af14739ee7dc311471de98f5f9d2c9191b18aedfe957f4a6ff791c709868ff58"
ARCHIVE_NAME = "speech_commands_v0.02.tar.gz"
MARKER_NAME = ".speech_commands_v0.02.complete.json"


def default_data_root(repo_root: Union[os.PathLike, str, None] = None) -> Path:
    """Return the repository-local data directory used by default.

    Keeping this path inside ``kwt-data`` makes a checkout portable:
    no command needs to know about the drive letter used on the machine that
    produced an earlier experiment.  The directory is ignored by Git because
    it contains the downloaded dataset and generated caches.
    """
    if repo_root is None:
        # data.py lives in <repo>/quantization/data.py.
        repo = Path(__file__).resolve().parents[1]
    else:
        repo = Path(repo_root).expanduser().resolve()
    return repo / "kwt-data"


def configured_data_root(repo_root: Union[os.PathLike, str, None] = None) -> Path:
    """Resolve ``KWT_DATA_ROOT`` or the portable repository-local default."""
    override = os.environ.get("KWT_DATA_ROOT")
    return Path(override).expanduser().resolve() if override else default_data_root(repo_root)


def _sha256(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _free_bytes(path: Path) -> int:
    return shutil.disk_usage(str(path)).free


def _safe_members(archive: tarfile.TarFile) -> Iterable[tarfile.TarInfo]:
    """Reject traversal, absolute names, links and non-file/dir entries."""
    for member in archive.getmembers():
        name = Path(member.name)
        if name.is_absolute() or ".." in name.parts:
            raise ValueError("unsafe archive member: %s" % member.name)
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise ValueError("unsupported archive member: %s" % member.name)
        yield member


def _extract_safely(archive_path: Path, destination: Path) -> int:
    temp = destination.with_name(destination.name + ".extracting")
    if temp.exists():
        shutil.rmtree(str(temp))
    temp.mkdir(parents=True)
    count = 0
    try:
        with tarfile.open(str(archive_path), mode="r:gz") as archive:
            members = list(_safe_members(archive))
            for member in members:
                target = (temp / member.name).resolve()
                if temp.resolve() not in target.parents and target != temp.resolve():
                    raise ValueError("archive member escapes destination: %s" % member.name)
            archive.extractall(str(temp), members=members)
            count = sum(1 for member in members if member.isfile() and member.name.lower().endswith(".wav"))
        if count == 0:
            raise ValueError("Speech Commands archive contained no WAV files")
        if destination.exists():
            shutil.rmtree(str(destination))
        temp.rename(destination)
    except Exception:
        if temp.exists():
            shutil.rmtree(str(temp), ignore_errors=True)
        raise
    return count


def _download_with_resume(url: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size == DATASET_SIZE:
        return
    # curl is used when available because the Python 3.8 TLS stack on legacy
    # TensorFlow environments can fail against current HTTPS endpoints.
    curl = shutil.which("curl.exe") or shutil.which("curl")
    if curl:
        command = [curl, "-L", "--fail", "--retry", "6", "--retry-delay", "5", "-C", "-", "-o", str(target), url]
        result = subprocess.run(command, check=False)
        if result.returncode == 0:
            return
    # Python fallback keeps a fresh machine usable when curl is not installed.
    # A Range request resumes a partial archive; servers that do not support
    # Range return 200 and are safely written from scratch.
    existing = target.stat().st_size if target.exists() else 0
    request = urllib.request.Request(url)
    if existing:
        request.add_header("Range", "bytes=%d-" % existing)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            append = existing > 0 and getattr(response, "status", 200) == 206
            mode = "ab" if append else "wb"
            with target.open(mode) as output:
                shutil.copyfileobj(response, output, length=8 * 1024 * 1024)
    except Exception as error:
        raise RuntimeError("dataset download failed; install curl or check network access: %s" % error) from error


def prepare_dataset(data_root: Union[os.PathLike, str], *, download: bool = True,
                    extract: bool = True, min_free_gib: float = 10.0) -> Dict[str, object]:
    """Download, validate and safely extract Speech Commands V2.

    Returns a JSON-serializable metadata dictionary.  A completion marker is
    written only after the archive hash and extracted WAV count are valid.
    """
    root = Path(data_root).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    archive = root / ARCHIVE_NAME
    data2 = root / "data2"
    marker = root / MARKER_NAME
    required = int(min_free_gib * (1024 ** 3))
    if _free_bytes(root) < required:
        raise RuntimeError("insufficient free space on %s (need %.1f GiB)" % (root, min_free_gib))
    if marker.is_file() and data2.is_dir():
        try:
            saved = json.loads(marker.read_text(encoding="utf-8"))
            wav_count = int(saved.get("wav_count", 0))
            if saved.get("sha256") == DATASET_SHA256 and wav_count > 0:
                saved.update({"archive": str(archive), "data_dir": str(data2)})
                marker.write_text(json.dumps(saved, indent=2, sort_keys=True), encoding="utf-8")
                return saved
        except (OSError, ValueError, TypeError):
            pass
    if download:
        # A same-sized but corrupt archive must not be passed to curl with
        # ``-C -``; discard it and start a clean download.  Partial archives
        # remain in place and are resumed.
        if archive.exists() and archive.stat().st_size == DATASET_SIZE:
            if _sha256(archive) != DATASET_SHA256:
                archive.unlink()
        elif archive.exists() and archive.stat().st_size > DATASET_SIZE:
            archive.unlink()
        _download_with_resume(DATASET_URL, archive)
    if not archive.exists():
        raise FileNotFoundError(str(archive))
    size = archive.stat().st_size
    if size != DATASET_SIZE:
        raise ValueError("incomplete dataset archive: %d bytes (expected %d)" % (size, DATASET_SIZE))
    digest = _sha256(archive)
    if digest != DATASET_SHA256:
        raise ValueError("dataset SHA256 mismatch: %s" % digest)
    wav_count = sum(1 for path in data2.rglob("*.wav")) if data2.exists() else 0
    if extract and wav_count == 0:
        wav_count = _extract_safely(archive, data2)
    if wav_count == 0:
        raise RuntimeError("no extracted Speech Commands WAV files")
    metadata = {
        "url": DATASET_URL,
        "archive": str(archive),
        "archive_bytes": size,
        "sha256": digest,
        "sha256_source": "tensorflow_datasets speech_commands checksums.tsv",
        "data_dir": str(data2),
        "wav_count": wav_count,
        "dataset": "speech_commands_v0.02",
    }
    marker.write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")
    return metadata


__all__ = ["prepare_dataset", "default_data_root", "configured_data_root", "DATASET_URL", "DATASET_SHA256", "DATASET_SIZE"]
