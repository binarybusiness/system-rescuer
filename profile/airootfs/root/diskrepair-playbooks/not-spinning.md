# HDD clicking, not spinning or not ready

Slug: `not-spinning`

## Triage

- From `inspect`: verdict unknown with no health data readable. First rule out the path: a USB bridge without SAT pass-through or a flash drive also exposes none, so try another adapter or a direct SATA port before blaming the drive.
- Check power: a different power supply or adapter, a different cable. A bridge that cannot power a 3.5-inch drive looks exactly like a dead drive.
- Listen: a steady spin-up whine then silence, repeated clicks, or a beeping/grinding spin-up each mean a different mechanical fault. Note which; do not guess.
- Do not power-cycle repeatedly, tap, freeze or open the drive. Clicking means heads that cannot find their servo data: each retry can scrape the platters.
- No data is recoverable by software from a drive that does not become ready. Hand it to a recovery lab (diskrepair's commercial price list names the lab-grade options; none is bought from here).

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in unknown; a reason contains one of 'gave no health data', 'not ready', 'spin', 'click', 'inquiry failed', 'identity failed'; priority 30 when several playbooks match.

## Register cases

- `7Y250P0_Y6423ZDE`

## Steps

1. Confirm the kernel sees the device and its size; read nothing from it.
   Tool: `lsblk` — catalog: host (base system)
   Command: `lsblk --json --bytes '{device}'`
   Stop and use a lab: Stop for a lab if the device appears and disappears, or never appears with power and cable checked.

2. Read the SMART health data through the bridge, trying SAT pass-through.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl -d sat --json -x '{device}'`
   Stop and use a lab: Stop for a lab if there is still no answer on a direct SATA port.

3. Read the identify data.
   Tool: `hdparm` — catalog: hdparm; route pacman:hdparm; writes: firmware
   Command: `hdparm -I '{device}'`
   Stop and use a lab: Stop for a lab if identify times out or returns a wrong model or capacity: that is the firmware-fault playbook.

4. Read the SCSI inquiry and the pending sense data.
   Tool: `sg_requests` — catalog: sg3_utils; route pacman:sg3_utils; writes: firmware
   Command: `sg_requests '{device}'`
   Stop and use a lab: Stop for a lab if the sense data reports not ready or a vendor-specific internal failure.

