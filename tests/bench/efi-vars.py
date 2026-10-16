#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""Firmware boot entries for the scenario bench, read from and made for
an OVMF variable store as virt-fw-vars dumps it (--output-json) and sets it
(--set-json).

    efi-vars.py option <title> <disk-image> <partition|esp> <path>
        a Boot#### variable's data (an EFI_LOAD_OPTION) as hex, with the
        device path HD(<partition>, GPT)/File(<path>) that efibootmgr and
        bootctl write; esp is the image's first EFI system partition
    efi-vars.py stick
        OVMF's own entry for the rescue stick (usb-storage on the qemu-xhci
        controller at PCI 00:08.0), with OVMF's signature for entries it
        made itself, so a boot without the stick drops it again
    efi-vars.py order <vars.json>
        the BootOrder, one Boot#### name per line
    efi-vars.py entries <vars.json>
        every Boot#### variable, those in BootOrder first and in its order:
        <name> TAB <title> TAB <partuuid or -> TAB <path or ->
    efi-vars.py pick <vars.json> <path-regex> <exclude-regex|-> <disk-image>...
        the name of the first entry (in BootOrder's order) whose HD() node
        is a partition of one of the images and whose path matches the
        regex and not the exclusion (both case-insensitive); exit status 1
        when there is none
    efi-vars.py partuuids <disk-image>...
        the PARTUUID of every partition on the images, one per line
    efi-vars.py string <vars.json> <vendor-guid> <name>
        a variable holding a UCS-2 string (as systemd-boot's do), as text;
        exit status 1 when it is not set
"""
import json
import re
import struct
import sys
import uuid

LOAD_OPTION_ACTIVE = 0x1
ESP_TYPE = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
# OVMF marks the boot options it makes for a device itself with this GUID in
# their optional data (EDKII's mBootOptionSignature).
OVMF_AUTO = bytes.fromhex("4eac0881119f594d850ee21a522c59b2")


def node(dtype: int, subtype: int, body: bytes) -> bytes:
    return struct.pack("<BBH", dtype, subtype, 4 + len(body)) + body


def ucs2(text: str) -> bytes:
    return (text + "\0").encode("utf-16-le")


def load_option(title: str, devpath: bytes, optdata: bytes = b"") -> str:
    devpath += node(0x7F, 0xFF, b"")
    return (struct.pack("<IH", LOAD_OPTION_ACTIVE, len(devpath)) + ucs2(title) + devpath + optdata).hex()


def partitions(image: str):
    """(number, type, partuuid, first LBA, LBA count) of each GPT partition."""
    with open(image, "rb") as f:
        f.seek(512)
        hdr = f.read(92)
        if hdr[:8] != b"EFI PART":
            return []
        lba, count, size = struct.unpack_from("<QII", hdr, 72)
        f.seek(lba * 512)
        table = f.read(count * size)
    out = []
    for i in range(count):
        e = table[i * size:(i + 1) * size]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        out.append((i + 1, uuid.UUID(bytes_le=e[:16]), uuid.UUID(bytes_le=e[16:32]), first, last - first + 1))
    return out


def option(title: str, image: str, part: str, path: str) -> str:
    parts = partitions(image)
    if part == "esp":
        match = [p for p in parts if p[1] == ESP_TYPE][:1]
    else:
        match = [p for p in parts if p[0] == int(part)]
    if not match:
        sys.exit(f"efi-vars.py: no partition {part} on {image}")
    num, _, partuuid, start, size = match[0]
    hd = node(4, 1, struct.pack("<IQQ", num, start, size) + partuuid.bytes_le + bytes([2, 2]))  # GPT, GUID signature
    return load_option(title, hd + node(4, 4, ucs2(path)))


def stick() -> str:
    devpath = (node(2, 1, struct.pack("<II", 0x0A0341D0, 0))  # PciRoot(0)
               + node(1, 1, bytes([0, 8]))                    # Pci(0x8, 0x0)
               + node(3, 5, bytes([0, 0])))                   # USB(0, 0)
    return load_option("UEFI QEMU QEMU USB HARDDRIVE 1-0000:00:08.0-1", devpath, OVMF_AUTO)


def variables(dump: str, guid: str = "8be4df61-93ca-11d2-aa0d-00e098032b8c"):
    with open(dump) as f:
        return {v["name"]: bytes.fromhex(v["data"]) for v in json.load(f)["variables"]
                if v["guid"].lower() == guid.lower()}


def order(vars_: dict):
    data = vars_.get("BootOrder", b"")
    return [f"Boot{n:04X}" for n in struct.unpack(f"<{len(data) // 2}H", data)]


def parse(data: bytes):
    """(title, partuuid or None, path or None) of a load option."""
    pathlen = struct.unpack_from("<H", data, 4)[0]
    end = 6
    while data[end:end + 2] != b"\0\0":
        end += 2
    title = data[6:end].decode("utf-16-le")
    devpath = data[end + 2:end + 2 + pathlen]
    partuuid = path = None
    i = 0
    while i + 4 <= len(devpath):
        dtype, subtype, length = struct.unpack_from("<BBH", devpath, i)
        if length < 4 or dtype == 0x7F:
            break
        body = devpath[i + 4:i + length]
        if (dtype, subtype) == (4, 1) and body[37:38] == b"\x02":
            partuuid = str(uuid.UUID(bytes_le=body[20:36]))
        elif (dtype, subtype) == (4, 4):
            path = body.decode("utf-16-le").rstrip("\0")
        i += length
    return title, partuuid, path


def entries(vars_: dict):
    names = order(vars_)
    names += sorted(n for n in vars_ if re.fullmatch(r"Boot[0-9A-F]{4}", n) and n not in names)
    return [(n, *parse(vars_[n])) for n in names if n in vars_]


def main() -> None:
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "option":
        print(option(*args))
    elif cmd == "stick":
        print(stick())
    elif cmd == "order":
        print("\n".join(order(variables(args[0]))))
    elif cmd == "entries":
        for name, title, partuuid, path in entries(variables(args[0])):
            print(f"{name}\t{title}\t{partuuid or '-'}\t{path or '-'}")
    elif cmd == "pick":
        dump, want, exclude, images = args[0], args[1], args[2], args[3:]
        uuids = {str(p[2]) for image in images for p in partitions(image)}
        for name, _, partuuid, path in entries(variables(dump)):
            if partuuid in uuids and path and re.search(want, path, re.I) \
                    and not (exclude != "-" and re.search(exclude, path, re.I)):
                print(name)
                return
        sys.exit(1)
    elif cmd == "partuuids":
        for image in args:
            for p in partitions(image):
                print(p[2])
    elif cmd == "string":
        data = variables(args[0], args[1]).get(args[2])
        if data is None:
            sys.exit(1)
        print(data.decode("utf-16-le").rstrip("\0"))
    else:
        sys.exit(f"efi-vars.py: no command {cmd}")


if __name__ == "__main__":
    main()
