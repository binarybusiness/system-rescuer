# ZFS or bcachefs import failure

Slug: `zfs-bcachefs-import`

## Triage

- Image every member first; neither filesystem is repaired in place from a degraded state without a copy.
- Always import read-only before any read-write or rewind import.
- The rewind (`zpool import -F`) discards the last transactions; the bcachefs fsck rewrites metadata. Both come last.

## Inspect selection

Symptom only: no health or partition-table signal shows a deletion.

## Register cases

- no register case yet

## Steps

1. Make a forensic image of every member before attempting import or repair.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue --force '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be imaged read-only into the named scratch image?
   Stop and use a lab: Stop for a lab if the drive clicks, resets, disappears, or read errors grow quickly.

2. ZFS: list importable pools and their state without importing.
   Tool: `zpool import` — catalog: zpool import read-only (ZFS); route boot-medium:zfs-utils; writes: no
   Command: `zpool import -d '{imagedir}'`
   On the rescue stick: unavailable on the rescue stick (zfs-utils needs an out-of-tree module per kernel); use another Linux machine with zfs-utils
   Stop and use a lab: Stop for a lab if no pool is listed or labels are missing on members.

3. ZFS: import read-only without mounting and without a cachefile.
   Tool: `zpool import` — catalog: zpool import read-only (ZFS); route boot-medium:zfs-utils; writes: no
   Command: `zpool import -o readonly=on -N -d '{imagedir}' '{pool}'`
   On the rescue stick: unavailable on the rescue stick (zfs-utils needs an out-of-tree module per kernel); use another Linux machine with zfs-utils
   Stop and use a lab: Stop for a lab if import fails with I/O or corrupt-pool errors.

4. ZFS: dry-run the transaction rewind to see how much would be lost.
   Tool: `zpool import -Fn` — catalog: zpool import rewind (ZFS); route boot-medium:zfs-utils; writes: yes
   Command: `zpool import -F -n -o readonly=on -d '{imagedir}' '{pool}'`
   On the rescue stick: unavailable on the rescue stick (zfs-utils needs an out-of-tree module per kernel); use another Linux machine with zfs-utils
   Stop and use a lab: Stop for a lab if the rewind would discard more than a few transaction groups.

5. ZFS: read-only rewind import on the image, last resort; nothing is written to the pool.
   Tool: `zpool import -F` — catalog: zpool import rewind (ZFS); route boot-medium:zfs-utils; writes: yes
   Command: `zpool import -F -o readonly=on -d '{imagedir}' '{pool}'`
   On the rescue stick: unavailable on the rescue stick (zfs-utils needs an out-of-tree module per kernel); use another Linux machine with zfs-utils
   OWNER DECISION REQUIRED:
   Ask the owner: May zpool import -F rewind this disk's pool and discard its last transactions?
   Stop and use a lab: Stop for a lab if the dry run lost data you need.

6. bcachefs: dry-run fsck of the image; no changes.
   Tool: `bcachefs fsck` — catalog: bcachefs fsck read-only check (bcachefs); route boot-medium:bcachefs-tools; writes: no
   Command: `bcachefs fsck -n '{image}'`
   Stop and use a lab: Stop for a lab if the superblock is unreadable; try recover-super.

7. bcachefs: repair with fsck, last resort.
   Tool: `bcachefs fsck` — catalog: bcachefs fsck repair (bcachefs); route boot-medium:bcachefs-tools; writes: yes
   Command: `bcachefs fsck -y '{image}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May bcachefs fsck -y rewrite this disk's metadata?
   Stop and use a lab: Stop for a lab if the dry run shows errors beyond a few inodes.

