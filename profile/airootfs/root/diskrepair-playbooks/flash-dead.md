# Dead flash media: no medium, 0 B or write-protected

Slug: `flash-dead`

## Triage

- From `inspect`: no health data, which a USB flash drive or a bridge without SAT pass-through always shows. This is a path or media question, not a SMART verdict; the HDD not-spinning playbook lists the power and adapter checks.
- Read the kernel's view first, without touching the medium: does the device appear, with what size? A size of 0 B, or `No medium found`, means the controller answers but exposes no NAND: it is in a ROM or fault state.
- A write-protect state has two causes: a physical switch (SD adapter) that can be moved, or a controller that has locked itself read-only after it detected failing flash. The second cannot be reverted by software and is a data-copying exercise, not a repair: read everything out and stop.
- For SD cards and eMMC the card's registers are readable with mmc-utils (the mmc(1) manual lists its read and write subcommands); on a USB stick the controller identity is read with `lsusb`. These reads are safe; erase, write-protect and firmware commands are owner decisions on that device.
- Stop for a recovery lab when the device shows 0 B or no medium and the data matters: chip-off or controller-mode recovery (PC-3000 Flash, quote only, in diskrepair's commercial price list) is outside this toolkit. A vendor mass-production tool rebuilds the translation layer but erases user data, and only suits a drive the owner has decided to reuse.

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in unknown; a reason contains one of 'gave no health data'; priority 25 when several playbooks match.

## Register cases

- no register case yet

## Steps

1. Confirm the kernel sees the device and its size; read nothing from it.
   Tool: `lsblk` — catalog: host (base system)
   Command: `lsblk --json --bytes '{device}'`
   Stop and use a lab: Stop for a lab if the size is 0 or the device appears and disappears.

2. Read the SCSI inquiry and the pending sense data (NOT READY or MEDIUM NOT PRESENT).
   Tool: `sg_requests` — catalog: sg3_utils; route pacman:sg3_utils; writes: firmware
   Command: `sg_requests '{device}'`
   Stop and use a lab: Stop for a lab if the sense reports medium not present on a device with a card or data.

3. Read the capacity over SCSI with the long form.
   Tool: `sg_readcap` — catalog: sg3_utils; route pacman:sg3_utils; writes: firmware
   Command: `sg_readcap -l '{device}'`
   Stop and use a lab: Stop for a lab if the capacity is 0 and the data matters.

4. Image whatever is readable: a fast pass, no scraping.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -n '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this flash device be imaged read-only into the named scratch image with a ddrescue fast pass (-n)?
   Stop and use a lab: Stop for a lab if nothing is readable or the device resets during the pass.

