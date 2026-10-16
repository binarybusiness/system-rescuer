#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""Turn raw audit records (ausearch --raw) into one JSON line per execve.

Each line holds the audit serial, its time (Unix seconds, the guest clock),
pid, ppid, exe and argv. Arguments that audit hex-encoded (spaces, quotes,
newlines) are decoded.

    ausearch --input-logs --raw -k rescue-exec | tests/bench/exec-record.py
"""
import json
import re
import sys

FIELD = re.compile(r'(\w+)=("(?:[^"]*)"|\S+)')


def value(raw: str) -> str:
    if raw.startswith('"'):
        return raw[1:-1]
    if raw != "(null)" and re.fullmatch(r"(?:[0-9A-F]{2})+", raw):
        return bytes.fromhex(raw).decode("utf-8", "replace")
    return raw


def main() -> None:
    events: dict[str, dict] = {}
    for line in sys.stdin:
        m = re.match(r"type=(\w+) msg=audit\(([\d.]+):(\d+)\):(.*)", line)
        if not m:
            continue
        kind, stamp, serial, rest = m.groups()
        fields = {k: v for k, v in FIELD.findall(rest)}
        ev = events.setdefault(serial, {"serial": int(serial), "time": float(stamp), "argv": {}})
        if kind == "SYSCALL":
            ev["pid"] = int(fields.get("pid", 0))
            ev["ppid"] = int(fields.get("ppid", 0))
            ev["exe"] = value(fields.get("exe", '""'))
        elif kind == "EXECVE":
            for k, v in fields.items():
                if re.fullmatch(r"a\d+", k):
                    ev["argv"][int(k[1:])] = value(v)
    for serial in sorted(events, key=int):
        ev = events[serial]
        if not ev["argv"]:
            continue
        ev["argv"] = [ev["argv"][i] for i in sorted(ev["argv"])]
        print(json.dumps(ev))


if __name__ == "__main__":
    main()
