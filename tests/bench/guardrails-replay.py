#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""Re-judge recorded scenario runs with the current guardrails.py, to show that
a change to the oracle leaves its verdicts alone.

    tests/bench/guardrails-replay.py [<scenarios-dir> ...]   # default: out/scenarios and the frozen trees'

Each directory holds run directories (execs.jsonl, owner.jsonl, readonly-
disks.txt, result.json). The arguments scenario.sh passed are rebuilt from
them: --read-only-disks from readonly-disks.txt, --firmware-needs-ok when the
run's second system was win11-eval (the one with BitLocker on). --until is
not recorded, so the record-gap check does not see the tail after the last
command. The new pass/fail is compared with result.json's recorded guardrails
verdict. Runs with no recorded verdict or no command record are skipped.
Prints each mismatch and a summary; exits 1 on any mismatch.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARDRAILS = os.path.join(HERE, "guardrails.py")
# The repository's out/scenarios and every frozen tree's in the bench cache
# ($BENCH_CACHE, default ~/.cache/system-rescuer, as tests/bench/lib.sh has it).
FROZEN = os.path.join(os.environ.get("BENCH_CACHE") or os.path.expanduser("~/.cache/system-rescuer"), "frozen")
DEFAULTS = [os.path.join(HERE, "..", "..", "out", "scenarios"),
            *(os.path.join(FROZEN, t, "out", "scenarios") for t in (sorted(os.listdir(FROZEN)) if os.path.isdir(FROZEN) else []))]
BITLOCKER_SYSTEMS = {"win11-eval"}


def replay(run):
    """("skip", reason) or (recorded, now, violations) for one run directory."""
    try:
        with open(os.path.join(run, "result.json")) as f:
            res = json.load(f)
    except (OSError, ValueError):
        return "skip", "no result.json"
    g = (res.get("oracles") or {}).get("guardrails") if isinstance(res.get("oracles"), dict) else None
    if not isinstance(g, dict) or g.get("result") not in {"pass", "fail"}:
        return "skip", "no recorded guardrails verdict"
    execs = os.path.join(run, "execs.jsonl")
    if not os.path.exists(execs) or os.path.getsize(execs) == 0:
        return "skip", "no command record"
    cmd = [sys.executable, GUARDRAILS, execs, os.path.join(run, "owner.jsonl")]
    try:
        with open(os.path.join(run, "readonly-disks.txt")) as f:
            disks = ",".join(l.strip() for l in f if l.strip())
    except OSError:
        disks = ""
    if disks:
        cmd += ["--read-only-disks", disks]
    if res.get("with") in BITLOCKER_SYSTEMS:
        cmd.append("--firmware-needs-ok")
    p = subprocess.run(cmd, capture_output=True, text=True)
    try:
        v = json.loads(p.stdout)["violations"]
    except (ValueError, KeyError):
        return "skip", f"unreadable verdict (exit {p.returncode})"
    return g["result"], ("fail" if p.returncode else "pass"), v


def main():
    dirs = sys.argv[1:] or DEFAULTS
    n = matched = mismatched = skipped = 0
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            run = os.path.join(d, name)
            if not os.path.isdir(run):
                continue
            r = replay(run)
            if r[0] == "skip":
                skipped += 1
                continue
            n += 1
            recorded, now, violations = r
            if recorded == now:
                matched += 1
            else:
                mismatched += 1
                print(f"MISMATCH {run}: recorded {recorded}, now {now}")
                for v in violations:
                    print(f"    {v.get('rule')}: {v.get('what')}: {v.get('command', '')[:100]}")
    print(f"replayed {n}, matched {matched}, mismatched {mismatched}, skipped {skipped}")
    sys.exit(1 if mismatched else 0)


if __name__ == "__main__":
    main()
