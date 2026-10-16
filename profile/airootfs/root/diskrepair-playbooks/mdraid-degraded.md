# Degraded or unassembled mdraid

Slug: `mdraid-degraded`

## Triage

- Do not re-add, resync or `--create` over members; a wrong create overwrites the superblocks and the data layout.
- Image every member first, then examine each member's superblock and compare event counts and update times.
- Assemble read-only first; force only members whose event counts are close, and only after the owner decides.

## Inspect selection

Symptom only: no health or partition-table signal shows a deletion.

## Register cases

- no register case yet

## Steps

1. Make a forensic image of every member before attempting repair.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue --force '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this member disk be imaged read-only into the named scratch image?
   Stop and use a lab: Stop for a lab if the drive clicks, resets, disappears, or read errors grow quickly.

2. Read each member's superblock: array UUID, role, event count and state.
   Tool: `mdadm --examine` — catalog: mdadm examine (mdraid); route pacman:mdadm; writes: no
   Command: `mdadm --examine '{image}'`
   Stop and use a lab: Stop for a lab if no md superblock is found or members disagree on the array UUID.

3. Assemble the array read-only from the members, naming them explicitly; --run starts it with a member missing, which mdadm otherwise refuses for an array that was clean at last stop.
   Tool: `mdadm --assemble` — catalog: mdadm assemble read-only (mdraid); route pacman:mdadm; writes: no
   Command: `mdadm --assemble --readonly --run '/dev/md/{array}' '{members}'`
   Stop and use a lab: Stop for a lab if assembly lists a member as non-fresh or the array stays inactive.

4. Force-assemble read-only, accepting a member with a slightly older event count.
   Tool: `mdadm --assemble --force` — catalog: mdadm assemble force (mdraid); route pacman:mdadm; writes: yes
   Command: `mdadm --assemble --force --readonly '/dev/md/{array}' '{members}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May mdadm --assemble --force update the superblocks of this disk's array members?
   Stop and use a lab: Stop for a lab if event counts differ widely or more members are stale than the RAID level tolerates.

5. Read the filesystem out of the assembled array before any resync or fsck.
   Tool: `dd` — catalog: host (base system)
   Command: `dd 'if=/dev/md/{array}' 'of={output}/array.bin' bs=1M status=none`
   Stop and use a lab: Stop for a lab if dd reports read errors.

