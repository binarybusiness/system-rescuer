#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""Judge diskrepair's playbooks on the stick with the guardrail oracle.

    python3 tests/bench/playbooks-check.py [<playbooks-dir>]

Every `Command:` line of every playbook (default: profile/airootfs/root/
diskrepair-playbooks/) is judged by guardrails.rule() twice: as written, where
{image} is an image file, and with {image} a real partition, as if an agent
applied the step to the disk itself. A step fails when a command breaks a
"never" rule, or needs an owner's OK and the step has no OWNER DECISION
REQUIRED line. Prints one line per failure and a summary; exits 1 on any.
Compare a regenerated export from diskrepair by passing its directory.
"""
import glob
import os
import re
import shlex
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import guardrails  # noqa: E402

DEFAULT = os.path.join(here, "..", "..", "profile", "airootfs", "root", "diskrepair-playbooks")
# Stand-ins for the playbooks' placeholders: a disk and its partitions are
# devices, everything else a file in /root.
SUBS = {
    "device": "/dev/sdb", "partition": "/dev/sdb1", "members": "/dev/sdb1 /dev/sdc1", "array": "/dev/md0",
    "mapname": "rescued", "map": "/root/rescue.map", "output": "/root/out.img", "imagedir": "/root/images",
    "mountpoint": "/mnt/x", "backup": "/root/backup.bin", "backup_sb": "32768", "blocksize": "4096",
    "gpt_backup": "/root/gpt.bak", "damaged_gpt_backup": "/root/gpt.bad", "inode": "12", "key": "/root/key",
    "last_sec": "1000", "lba": "1000", "lv": "root", "pv_uuid": "abcd-ef", "sfdisk_dump": "/root/sfdisk.dump",
    "vg": "vg0", "pool": "tank",
}
IMAGES = (("as written", "/root/images/disk.img"), ("on a real partition", "/dev/sdb1"))


def expand(cmd, image):
    subs = dict(SUBS, image=image)
    return re.sub(r"\{([a-z_]+)\}", lambda m: subs.get(m.group(1), m.group(0)), cmd)


def check(bundle):
    """(failures, commands judged) for the playbooks in bundle."""
    failures, judged = [], 0
    paths = sorted(glob.glob(os.path.join(bundle, "*.md")))
    if not paths:
        return [f"no playbooks in {bundle}"], 0
    for path in paths:
        name = os.path.basename(path)
        for step in re.split(r"\n(?=\d+\. )", open(path).read()):
            num = step.split(".", 1)[0] if step[:1].isdigit() else "?"
            owner_ok = "OWNER DECISION REQUIRED" in step
            for cmd in re.findall(r"^\s*Command: `(.*)`\s*$", step, re.M):
                for where, image in IMAGES:
                    # A pipeline or a list: each simple command on its own.
                    for part in re.split(r"\s*(?:\|\||&&|\||;)\s*", expand(cmd, image)):
                        try:
                            argv = shlex.split(part)
                        except ValueError as e:
                            failures.append(f"{name} step {num}: cannot parse {part!r}: {e}")
                            continue
                        if not argv:
                            continue
                        judged += 1
                        v = guardrails.rule(argv)
                        if v and v[0] == "never":
                            failures.append(f"{name} step {num} ({where}): never — {v[1]}: {part}")
                        elif v and v[0] == "ok" and not owner_ok:
                            failures.append(f"{name} step {num} ({where}): needs an owner's OK the step does not ask for — {v[1]}: {part}")
    return failures, judged


def main():
    bundle = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    failures, judged = check(bundle)
    for f in failures:
        print(f)
    print(f"playbooks-check: {judged} commands judged, {len(failures)} failures")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
