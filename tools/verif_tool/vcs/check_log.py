#!/usr/bin/env python3
"""Check VCS/UVM results using only the Python 3.6+ standard library.

Usage: python3 check_log.py LOG --exit-code RC [--require-completion]
                           [--require-fsdb PATH] [--json PATH]

Print one JSON object containing verdict, first_error and final summary counts.
--json also saves that object to a file. Exit status: 0 = PASS, 1 = failed
verification/requirements, 2 = input/output or command-line error. A required
FSDB must be a nonempty regular file. Log input is UTF-8 (a BOM is accepted).
No simulator is launched. RC must be the actual simulator process exit code.
"""

import argparse
import json
import os
import re
import stat


_SUMMARY = re.compile(r"---[ \t]+UVM Report Summary[ \t]+---")
_COUNT = re.compile(r"^[ \t]*(UVM_ERROR|UVM_FATAL)[ \t]*:[ \t]*([0-9]+)[ \t]*$")
_UVM_MESSAGE = re.compile(r"\bUVM_(?:ERROR|FATAL)\b")
_FINISH = re.compile(r"\$finish\b", re.IGNORECASE)
_DIAGNOSTICS = (
    (re.compile(r"\bError-|\bError[ \t]*:|\bFatal(?:-|[ \t]*:)"
                r"|^[ \t]*(?:\*\*[ \t]*)?Fatal\b", re.IGNORECASE),
     "VCS error/fatal diagnostic"),
    (re.compile(r"\bAssertion\b.*\bfailed\b|\bfailed[ \t]+at\b"
                r"|\bOffending\b|\$fatal\b", re.IGNORECASE),
     "Assertion failure or $fatal"),
    (re.compile(r"\btimeout\b|\btimed[ \t-]+out\b|\btime[ \t-]+out\b",
                re.IGNORECASE),
     "Simulation timeout"),
)


def _fail(report, reason, line=None, text=None):
    if report["verdict"] == "PASS":
        report["verdict"] = "FAIL"
    if report["first_error"] is None:
        report["first_error"] = {"reason": reason, "line": line, "text": text}


def _io_error(report, reason):
    report["verdict"] = "ERROR"
    report["first_error"] = {"reason": reason, "line": None, "text": None}


def check_log(log_path, exit_code, require_completion=False, require_fsdb=None,
              completion_marker="KSE_TEST_COMPLETE"):
    """Return a JSON-serializable report; retain the first diagnostic in log order.

    Each summary header resets the counts, so an incomplete final summary
    cannot borrow a count from an earlier one. Valid zero count lines inside
    summaries are metadata. All other UVM_ERROR/UVM_FATAL lines, and any
    nonzero summary counts, are persistent failures even after later zeros.
    """
    completion = re.compile(r"\b" + re.escape(completion_marker) + r"\b")
    report = {
        "verdict": "PASS",
        "first_error": None,
        "counts": {"UVM_ERROR": None, "UVM_FATAL": None},
        "log": str(log_path),
        "exit_code": exit_code,
        "summary_found": False,
        "summary_line": None,
        "completion_found": False,
        "completion_marker": completion_marker,
        "fsdb": str(require_fsdb) if require_fsdb is not None else None,
        "fsdb_size": None,
    }
    try:
        with open(log_path, "r", encoding="utf-8-sig") as log:
            for line_number, raw_line in enumerate(log, 1):
                line = raw_line.rstrip("\r\n")
                if _SUMMARY.search(line):
                    report["summary_found"] = True
                    report["summary_line"] = line_number
                    report["counts"] = {"UVM_ERROR": None, "UVM_FATAL": None}
                if completion.search(line):
                    report["completion_found"] = True

                count = _COUNT.fullmatch(line)
                if count and report["summary_found"]:
                    severity, digits = count.groups()
                    value = int(digits)
                    report["counts"][severity] = value
                    if value != 0:
                        _fail(report, "Nonzero {} summary count: {}".format(
                            severity, value), line_number, line)
                    continue
                if _UVM_MESSAGE.search(line):
                    _fail(report, "UVM_ERROR/UVM_FATAL message or invalid count",
                          line_number, line)
                for pattern, reason in _DIAGNOSTICS:
                    if pattern.search(line):
                        _fail(report, reason, line_number, line)
                        break
                if (_FINISH.search(line) and
                        (not report["summary_found"] or
                         any(value is None for value in report["counts"].values()))):
                    _fail(report, "$finish before a complete UVM report summary",
                          line_number, line)
    except (OSError, UnicodeError) as error:
        _io_error(report, "Cannot read log: {}".format(error))
        return report

    if exit_code != 0:
        _fail(report, "Simulator exit code is {} (expected 0)".format(exit_code))
    if not report["summary_found"]:
        _fail(report, "Missing --- UVM Report Summary ---")
    else:
        for severity, value in sorted(report["counts"].items()):
            if value is None:
                _fail(report, "Missing valid {} count in final summary".format(severity))
    if require_completion and not report["completion_found"]:
        _fail(report, "Missing " + completion_marker)
    if require_fsdb is not None:
        try:
            info = os.stat(require_fsdb)
        except (FileNotFoundError, NotADirectoryError):
            _fail(report, "Required FSDB does not exist: {}".format(require_fsdb))
        except OSError as error:
            _io_error(report, "Cannot inspect required FSDB: {}".format(error))
        else:
            report["fsdb_size"] = info.st_size
            if not stat.S_ISREG(info.st_mode) or info.st_size == 0:
                _fail(report, "Required FSDB is not a nonempty regular file: {}".format(
                    require_fsdb))
    return report


def _same_file(left, right):
    if os.path.normcase(os.path.abspath(left)) == os.path.normcase(os.path.abspath(right)):
        return True
    try:
        return os.path.samefile(left, right)
    except OSError:
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", metavar="LOG", help="VCS/UVM log to read (UTF-8)")
    parser.add_argument("--exit-code", metavar="RC", type=int, required=True,
                        help="actual simulator process exit code")
    parser.add_argument("--require-completion", action="store_true",
                        help="require an KSE_TEST_COMPLETE marker")
    parser.add_argument("--completion-marker", default="KSE_TEST_COMPLETE",
                        help="literal completion marker (default: KSE_TEST_COMPLETE)")
    parser.add_argument("--require-fsdb", metavar="PATH",
                        help="require a nonempty regular FSDB file")
    parser.add_argument("--json", dest="json_path", metavar="PATH",
                        help="also write the JSON report to PATH")
    args = parser.parse_args(argv)
    report = check_log(args.log, args.exit_code, args.require_completion, args.require_fsdb,
                       args.completion_marker)
    if args.json_path is not None:
        try:
            for input_path in (args.log, args.require_fsdb):
                if input_path is not None and _same_file(args.json_path, input_path):
                    raise OSError("JSON output must not overwrite an input file")
            with open(args.json_path, "w", encoding="utf-8", newline="\n") as output:
                json.dump(report, output, ensure_ascii=True, indent=2, sort_keys=True)
                output.write("\n")
        except OSError as error:
            _io_error(report, "Cannot write JSON report: {}".format(error))
    print(json.dumps(report, ensure_ascii=True, sort_keys=True))
    return {"PASS": 0, "FAIL": 1, "ERROR": 2}[report["verdict"]]


if __name__ == "__main__":
    raise SystemExit(main())
