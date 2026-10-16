# SSD firmware panic: placeholder identity or capacity

Slug: `ssd-firmware-panic`

## Triage

- Signs from `inspect`: a model that is not the label (for example `SATAFIRM S11`), an error string such as `BAD_CTX 0000013x` in the serial field, or a capacity of a few megabytes or zero. The controller is running its boot ROM or an error path, not its translation layer: the NAND may be intact, but the logical-to-physical map is not loaded.
- Phison S11: reported as the model `SATAFIRM S11` with 0 bytes or about 2 MB; recovery is by shorting controller pads and loading a volatile loader with a commercial tool. Source: a commercial recovery lab's published description (Rossmann Repair Group), a lead not confirmed elsewhere; the pad positions are not published in text.
- Intel 8 MB bug: an Intel 320-series drive reports 8 MB and the serial `BAD_CTX 0000013x` after an unexpected power loss. Firmware 4PC10362 fixed the original bug, but Intel's moderator says the 8 MB state is a designed failure mode the drive enters when it can no longer operate reliably, on current firmware most likely failed NAND, and advises a warranty return. Source: Intel Communities thread 109323 (https://communities.intel.com/thread/109323), vendor forum.
- SandForce panic: a SandForce-controller drive that falls back to a minimal capacity after a firmware assertion. No primary source was read for this toolkit; the same lead-tier caveat applies.
- Nothing in the open toolkit repairs this state. Do not write, format, secure erase, flash firmware or short pads: a write to a drive in this state can destroy the map for good. Identify reads only.
- Check the path first (another SATA port, one cold power-up). If the placeholder identity persists, stop: a recovery lab with a ROM-mode tool (PC-3000 SSD, quote only), or a firmware-lab session on an owner-designated donor drive; see diskrepair's commercial price list and its firmware-lab guide.

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in failing, watch, unknown; a reason contains one of 'satafirm', 'bad_ctx', 'placeholder'; priority 60 when several playbooks match. Also selected when the disk model contains one of 'satafirm'. Also selected when the reported capacity is above 0 and at most 16777216 bytes (a placeholder capacity).

## Register cases

- no register case yet

## Steps

1. Read the identify data and compare model, serial and capacity with the label.
   Tool: `hdparm` — catalog: hdparm; route pacman:hdparm; writes: firmware
   Command: `hdparm -I '{device}'`
   Stop and use a lab: Stop for a lab if identify reports a placeholder model such as SATAFIRM, a BAD_CTX serial, or a capacity of a few megabytes.

2. Read the capacity over SCSI with the long form.
   Tool: `sg_readcap` — catalog: sg3_utils; route pacman:sg3_utils; writes: firmware
   Command: `sg_readcap -l '{device}'`
   Stop and use a lab: Stop for a lab if the capacity is 0 or a few megabytes after one cold power-up.

3. Read the health data once, to see whether the controller answers SMART at all.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl --json -x '{device}'`
   Stop and use a lab: Stop for a lab if it answers only with errors; do not repeat it in a loop.

