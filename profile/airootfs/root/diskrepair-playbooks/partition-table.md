# Deleted or damaged partition table

Slug: `partition-table`

## Triage

- Do not write the original disk until its image is complete and checked.
- Use the image for every recovery attempt; preserve any known-good table dump or GPT backup.

## Inspect selection

Uses `inspect disks[].verdict plus saved lsblk blockdevices[].pttype, children[].fstype and size`: mode partition-table; verdict in healthy; blank-child threshold 90%.

## Register cases

- no register case yet

## Steps

1. Make a forensic image before attempting repair.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue --force '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be imaged read-only into the named scratch image?
   Stop and use a lab: Stop for a lab if the drive clicks, resets, disappears, or read errors grow quickly.

2. Save the damaged GPT metadata as evidence when readable.
   Tool: `sgdisk` — catalog: sgdisk backup and restore; route pacman:gptfdisk; writes: yes
   Command: `sgdisk '--backup={damaged_gpt_backup}' '{image}'`
   Stop and use a lab: Stop for a lab if the GPT is already unreadable; do not overwrite an existing backup.

3. Save the damaged partition layout as evidence when readable.
   Tool: `sfdisk` — catalog: sfdisk dump and restore; route pacman:util-linux; writes: yes
   Command: `sfdisk --dump '{image}'`
   Stop and use a lab: Stop for a lab if the table cannot be read or its layout is surprising.

4. Restore a pre-failure GPT backup when it exists.
   Tool: `sgdisk` — catalog: sgdisk backup and restore; route pacman:gptfdisk; writes: yes
   Command: `sgdisk '--load-backup={gpt_backup}' '{image}'`
   Only when: `backup_exists`
   OWNER DECISION REQUIRED:
   Ask the owner: May the GPT backup be loaded onto this image copy (sgdisk --load-backup), rewriting its partition table?
   Stop and use a lab: Stop for a lab if no backup from this exact image exists.

5. Restore a pre-failure sfdisk dump when it exists.
   Tool: `sfdisk` — catalog: sfdisk dump and restore; route pacman:util-linux; writes: yes
   Command: `sfdisk -q '{image}'`
   Only when: `dump_exists`
   Standard input: `{sfdisk_dump}`
   OWNER DECISION REQUIRED:
   Ask the owner: May the saved partition dump be applied to this image copy (sfdisk), rewriting its partition table?
   Stop and use a lab: Stop for a lab if the dump was not made from this exact disk.

6. Rebuild a primary GPT from its intact backup header.
   Tool: `gdisk` — catalog: gdisk; route pacman:gptfdisk; writes: yes
   Command: `gdisk '{image}'`
   Only when: `gpt_backup_header_intact`
   Standard input: `r\nb\nc\ny\nw\ny\n`
   OWNER DECISION REQUIRED:
   Ask the owner: May gdisk write a rebuilt partition table to this image copy?
   Stop and use a lab: Stop for a lab if both GPT headers are damaged or the backup conflicts.

7. Only with no usable backup, have TestDisk search and write the table.
   Tool: `TestDisk` — catalog: TestDisk; route pacman:testdisk; writes: yes
   Command: `testdisk /cmd '{image}' partition_i386,analyze,search,noconfirm,write`
   Only when: `no_backup`
   OWNER DECISION REQUIRED:
   Ask the owner: May TestDisk write the partition table it finds to this image copy?
   Stop and use a lab: Stop for a lab if discovered starts or sizes conflict with known data.

