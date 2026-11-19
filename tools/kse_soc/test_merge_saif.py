#!/usr/bin/env python3
"""Regression cases for scoring-window SAIF state accounting."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MERGER = Path(__file__).with_name("merge_saif.py")


def window(t0, t1, tx=0, tz=None, tc=0, signal="data"):
    z = "" if tz is None else f" (TZ {tz})"
    duration = t0 + t1 + tx + (tz or 0)
    return (f"(SAIFILE\n(DURATION {duration})\n(INSTANCE dut\n(NET\n({signal}\n"
            f" (T0 {t0}) (T1 {t1}) (TX {tx}){z}\n (TC {tc}) (IG 0)\n)\n)\n)\n)\n")


class MergeWindows(unittest.TestCase):
    def merge(self, *inputs):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            paths = []
            for i, content in enumerate(inputs):
                p = root / f"{i}.saif"
                p.write_text(content)
                paths.append(str(p))
            out = root / "merged.saif"
            proc = subprocess.run([sys.executable, str(MERGER), str(out), *paths],
                                  text=True, capture_output=True)
            return proc, out.read_text() if out.exists() else ""

    def test_known_states_and_transitions(self):
        p, out = self.merge(window(7, 2, 1, tc=3), window(4, 5, 1, tc=7))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("(DURATION 20)", out)
        self.assertIn("(T0 11) (T1 7) (TX 2)", out)
        self.assertIn("(TC 10)", out)
        self.assertNotIn("(TZ", out)

    def test_high_impedance_is_summed_even_when_constant(self):
        p, out = self.merge(window(0, 0, tz=10), window(0, 0, tz=10))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("(DURATION 20)", out)
        self.assertIn("(TZ 20)", out)

    def test_optional_high_impedance_in_either_input_order(self):
        normal, floating = window(8, 2), window(0, 0, tz=10)
        for inputs in [(normal, floating), (floating, normal)]:
            with self.subTest(inputs=inputs):
                p, out = self.merge(*inputs)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertIn("(DURATION 20)", out)
                self.assertIn("(T0 8) (T1 2) (TX 0) (TZ 10)", out)

    def test_different_signal_or_missing_field_rejected(self):
        for invalid in [window(8, 2, signal="other"),
                        window(8, 2).replace(" (TX 0)", "")]:
            p, _ = self.merge(window(8, 2), invalid)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn("structure differs", p.stderr)

    def test_missing_record_rejected(self):
        p, _ = self.merge(window(8, 2), window(8, 2) + ")\n")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("different lengths", p.stderr)


if __name__ == "__main__":
    unittest.main()
