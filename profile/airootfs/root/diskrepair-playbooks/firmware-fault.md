# HDD suspected firmware fault

Slug: `firmware-fault`

## Triage

- Signs from `inspect`: a wrong or zero capacity, vendor-specific internal target failure sense (ASC 0x44), a drive stuck busy or locked up, or an identify that returns firmware-area nonsense (a placeholder model, a different serial, a wrong sector size).
- These are firmware or service-area faults. The platters may be fine, but software cannot repair the service area, and ordinary I/O only adds more failed commands.
- Check the path before concluding a fault: a second adapter or a direct SATA port, and one cold power-up (not repeated cycles). A bridge reporting the drive not ready during spin-up can raise the same sense (see the register case).
- Read-only identify and sense reads only. No writes, resets, ATA security, DCO/HPA changes, firmware download or terminal commands without the owner's decision on that disk.
- Next steps are not in this toolkit's software: a firmware-lab session on an owner-designated donor drive for open-route families (diskrepair's firmware-lab guide), or a recovery lab (diskrepair's commercial price list names DFL-SRP, PC-3000 Portable and MRT options; nothing is bought from here).

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in failing, watch, unknown; a reason contains one of 'internal target failure', 'asc 0x44', 'asc 44', 'zero capacity', 'read capacity failed', 'locked up', 'firmware'; priority 40 when several playbooks match.

## Register cases

- `ST22000NM001E_ZX20MHHP`

## Steps

1. Read the identify data and compare model, serial, capacity and sector size with the label.
   Tool: `hdparm` — catalog: hdparm; route pacman:hdparm; writes: firmware
   Command: `hdparm -I '{device}'`
   Stop and use a lab: Stop for a lab if identify reports a placeholder model, zero capacity or a different serial.

2. Read the native max address and DCO identify to separate a firmware fault from a capacity limit.
   Tool: `hdparm` — catalog: hdparm; route pacman:hdparm; writes: firmware
   Command: `hdparm -N '{device}'`
   Stop and use a lab: Stop for a lab if native max is zero or disagrees with the label.

3. Read the capacity over SCSI with the long form.
   Tool: `sg_readcap` — catalog: sg3_utils; route pacman:sg3_utils; writes: firmware
   Command: `sg_readcap -l '{device}'`
   Stop and use a lab: Stop for a lab if the capacity is 0 or the command fails with ASC 0x44.

4. Read the current sense data of the drive.
   Tool: `sg_requests` — catalog: sg3_utils; route pacman:sg3_utils; writes: firmware
   Command: `sg_requests '{device}'`
   Stop and use a lab: Stop for a lab if the sense stays at an internal target failure after one cold power-up.

5. Read the health data with SAT pass-through, once.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl -d sat --json -x '{device}'`
   Stop and use a lab: Stop for a lab if it answers only with errors; do not repeat it in a loop.

