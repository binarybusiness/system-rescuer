# SATA SSD read-only or missing

Slug: `ssd-readonly`

## Triage

- From `inspect`: a wear, spare-reserve or life attribute at or below its threshold now, or a drive that no longer answers at all. An SSD that has used its reserve of spare blocks is designed to fall into a read-only or unresponsive state; it is end of life, not a fault to repair.
- A drive that vanished: check the path first (another SATA port and cable, one cold power-up, not repeated cycles). A drive that comes back with a placeholder model or capacity is the firmware-panic playbook; one that returns read-only has a controller lock that no OS-level flag removes.
- Read first, write nothing: the documented route is to read everything out before any erase, format or firmware change. Image first, a fast pass then bounded retries.
- ATA Secure Erase, sanitize and firmware updates can sometimes revive a read-only drive, but they destroy all data and a firmware update can brick a drive: each is an owner decision on that disk, taken only after the image is complete or the data is declared not needed. A frozen drive refuses security commands until a power cycle; do not force one.
- A revived end-of-life SSD is not trustworthy: it is a data-copying exercise, then replacement.
- Stop for a recovery lab or the firmware lab when the drive never returns, returns read-only with data that matters, or reports a placeholder identity; priced options are in diskrepair's commercial price list (PC-3000 SSD is the ROM-mode route, quote only).

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in failing, watch, unknown; a reason contains one of 'wear', 'reservd', 'reserve', 'life', 'erase fail', 'program fail', 'gave no health data'; priority 15 when several playbooks match.

## Register cases

- no register case yet

## Steps

1. Read the full SMART data: wear, reserve, life-left and reallocation attributes with their thresholds.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl --json -x '{device}'`
   Stop and use a lab: Stop for a lab if there is no answer, or every attribute reads zero or a placeholder.

2. Read the device statistics log for percentage used and lifetime writes.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl --json -l devstat '{device}'`
   Stop and use a lab: Stop for a lab if percentage used is at or past 100 and the data matters: image now.

3. Read the identify data: model, firmware, capacity and the security state (frozen, locked).
   Tool: `hdparm` — catalog: hdparm; route pacman:hdparm; writes: firmware
   Command: `hdparm -I '{device}'`
   Stop and use a lab: Stop for a lab if identify reports a placeholder model or capacity: that is the firmware-panic playbook.

4. Image the drive read-only: a fast pass first, no scraping.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -n '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this SSD be imaged read-only into the named scratch image with a ddrescue fast pass (-n)?
   Stop and use a lab: Stop for a lab if the drive drops off the bus during the pass or most of it fails.

5. Set the temporary ATA security password, the first half of a Secure Erase (only after the image is complete).
   Not on the rescue stick — owner-attended workstation only

6. ATA Secure Erase to try to revive a read-only SSD (destroys all data on it).
   Not on the rescue stick — owner-attended workstation only

7. Apply the vendor's firmware update when the vendor lists one for this model (can brick the drive).
   Not on the rescue stick — owner-attended workstation only

