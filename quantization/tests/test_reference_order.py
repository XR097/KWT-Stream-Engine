"""Processor construction must not depend on gfile.Glob enumeration order."""
from quantization.reference import _SortedGfile


class _FakeGfile:
    Exists = staticmethod(lambda path: path == "present")

    def __init__(self):
        self.calls = 0

    def Glob(self, pattern):  # noqa: N802
        self.calls += 1
        return ["b/2.wav", "a/1.wav", "c/0.wav"] if self.calls % 2 else ["c/0.wav", "b/2.wav", "a/1.wav"]


def test_sorted_gfile_is_order_independent_and_forwards_other_api():
    gfile = _SortedGfile(_FakeGfile())
    assert gfile.Glob("*/*.wav") == gfile.Glob("*/*.wav") == ["a/1.wav", "b/2.wav", "c/0.wav"]
    assert gfile.Exists("present") and not gfile.Exists("missing")
