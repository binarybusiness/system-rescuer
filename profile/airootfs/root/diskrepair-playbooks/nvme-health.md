# NVMe critical warning or media errors

Slug: `nvme-health`

## Triage

- From `inspect`: a critical warning (NVMe Base spec, SMART / Health Information log: bit 0 available spare below threshold, bit 1 temperature, bit 2 reliability degraded, bit 3 read-only, bit 4 volatile memory backup failed), available spare below its threshold, media and data integrity errors above zero, or endurance used near or past 100%.
- Critical warning bit 3 (media placed in read-only mode) and bit 2 (reliability degraded) mean the drive may stop accepting writes or lose data on its own; every extra power-on and write counts. Read the logs once, then image.
- Image first where data matters: one fast read-only pass, then bounded retries on the same mapfile. A namespace that is write protected also refuses Format and Sanitize (NVMe Base Specification 2.0c), so a failed format is not by itself a worse fault.
- Endurance used above 100% or spare below threshold with no media errors is wear, not damage: the drive is still readable, but replace it and copy the data off now.
- Format, sanitize, namespace and firmware commands destroy data or change the drive: each is an owner decision on that disk, asked after the image is complete.
- Stop for a recovery lab when media errors keep growing during imaging, the namespace disappears, or the controller stops answering identify (see the firmware-panic playbook). The lab and firmware-lab options are priced in diskrepair's commercial price list; nothing is bought from here.

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in failing, watch; a reason contains one of 'nvme critical warning', 'available spare', 'media and data integrity', 'of rated endurance used'; priority 50 when several playbooks match.

## Register cases

- no register case yet

## Steps

1. Read the SMART / Health Information log: critical warning, available spare, endurance used, media errors.
   Tool: `nvme-cli` — catalog: nvme-cli SSD inspection; route pacman:nvme-cli; writes: no
   Command: `nvme smart-log '{device}'`
   Stop and use a lab: Stop for a lab if the critical warning shows read-only (bit 3) or reliability degraded (bit 2) and the data matters: image before anything else.

2. Read the controller error log entries.
   Tool: `nvme-cli` — catalog: nvme-cli SSD inspection; route pacman:nvme-cli; writes: no
   Command: `nvme error-log '{device}'`
   Stop and use a lab: Stop for a lab if the error log fills with new media entries between two reads.

3. Read the controller identity: model, serial, firmware revision and capacity.
   Tool: `nvme-cli` — catalog: nvme-cli SSD inspection; route pacman:nvme-cli; writes: no
   Command: `nvme id-ctrl '{device}'`
   Stop and use a lab: Stop for a lab if identify fails, or reports a placeholder model or capacity: that is the firmware-panic playbook.

4. Image the namespace read-only: a fast pass first, then retries on the same mapfile.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -n '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this NVMe namespace be imaged read-only into the named scratch image with a ddrescue fast pass (-n)?
   Stop and use a lab: Stop for a lab if the namespace drops off the bus during the pass or most of it fails.

5. After the image is complete and verified, format the namespace with a user-data erase to test whether the drive can be reused (destroys all data).
   Not on the rescue stick — owner-attended workstation only

