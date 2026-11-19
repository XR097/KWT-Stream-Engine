"""Optional ctypes accelerator; the reference retains its NumPy fallback.

Build native_mac.c with an optimizing C compiler, and explicitly set
KWT_ASIC_MAC_LIBRARY. No compilation or binary writes occur on import.
"""
import ctypes
import os
import numpy as np

_library = None
_path = None


def measured_matmul(a, b):
    global _library, _path
    path = os.environ.get("KWT_ASIC_MAC_LIBRARY")
    if not path:
        return None
    if _library is None or path != _path:
        _library = ctypes.CDLL(path)
        _path = path
        pointer = np.ctypeslib.ndpointer(dtype=np.int32, flags="C_CONTIGUOUS")
        _library.kwt_mac.argtypes = [pointer, pointer, pointer] + [ctypes.c_int] * 6 + [pointer]
        _library.kwt_mac.restype = None
    if a.ndim not in (2, 3) or b.ndim not in (2, 3):
        return None
    batch = max(a.shape[0] if a.ndim == 3 else 1, b.shape[0] if b.ndim == 3 else 1)
    if any(v.ndim == 3 and v.shape[0] not in (1, batch) for v in (a, b)):
        return None
    m, k, n = a.shape[-2], a.shape[-1], b.shape[-1]
    if b.shape[-2] != k:
        raise ValueError("matmul inner dimension mismatch")
    a, b = np.ascontiguousarray(a, dtype=np.int32), np.ascontiguousarray(b, dtype=np.int32)
    out = np.empty((batch, m, n), dtype=np.int32)
    extrema = np.empty(2, dtype=np.int32)
    _library.kwt_mac(a, b, out, batch, m, k, n,
                     int(a.ndim == 2 or a.shape[0] == 1),
                     int(b.ndim == 2 or b.shape[0] == 1), extrema)
    return (out[0] if a.ndim == b.ndim == 2 else out), extrema
