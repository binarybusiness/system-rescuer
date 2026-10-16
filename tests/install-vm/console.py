#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""Drive a guest's serial console over a unix socket (tests/install-vm.sh).

    console.py <socket> <timeout-seconds> < commands

Answers the first-boot wizard (setting a throwaway root password, since the
image's console login refuses an empty one), logs in as root and then runs each stdin line as a shell command, waiting
for it to finish. Exits non-zero if a command fails or the console stops
answering. Everything the guest prints goes to stderr.
"""
import re
import socket
import sys
import time

# The scratch guest's root password: a throwaway for a VM that has only a
# loopback-forwarded port and is deleted after the run.
PASSWORD = "install-vm-test"
ESC = re.compile(r"\x1b\[[0-9;?=]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b[=>]|\r")


class Console:
    def __init__(self, path, timeout):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.sock.settimeout(1)
        self.buf = ""
        self.deadline = time.time() + timeout

    def pump(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            data = b""
        text = ESC.sub("", data.decode("utf-8", "replace"))
        sys.stderr.write(text)
        sys.stderr.flush()
        self.buf += text
        if time.time() > self.deadline:
            sys.exit("console: timed out; last output: " + self.buf[-300:])

    def send(self, text, pace=0.01):
        for ch in text:
            self.sock.sendall(ch.encode())
            time.sleep(pace)

    def expect(self, pattern, send=None):
        rx = re.compile(pattern, re.M)
        while True:
            m = rx.search(self.buf)
            if m:
                self.buf = self.buf[m.end():]
                return m
            self.pump()


def main():
    path, timeout = sys.argv[1], float(sys.argv[2])
    con = Console(path, timeout)
    # First-boot wizard and login: answer each until a shell prompt appears.
    con.send("\r")
    while True:
        con.pump()
        tail = con.buf[-2000:]
        if re.search(r"root@[^\n]*# ?$", tail, re.M):
            break
        if re.search(r"(root password|Retype|Password:)[^\n]*$", tail, re.M):
            con.buf = ""
            con.send(PASSWORD + "\r")
        elif re.search(r"(empty to skip|press TAB for no echo)[^\n]*$", tail, re.M) or "Press any key" in tail:
            con.buf = ""
            con.send("\r")
        elif re.search(r"login: *$", tail, re.M):
            con.buf = ""
            con.send("root\r")
    con.buf = ""
    n = 0
    for cmd in sys.stdin:
        cmd = cmd.rstrip("\n")
        if not cmd:
            continue
        n += 1
        con.send(f"{cmd}; echo \"DONE-{n}-$?\"\r")
        m = con.expect(rf"^DONE-{n}-(\d+)$")
        if m.group(1) != "0":
            sys.exit(f"console: command failed ({m.group(1)}): {cmd}")


main()
