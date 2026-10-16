# Corrupt filesystem (ext4, btrfs)

Slug: `filesystem-corrupt`

## Triage

- Stop mounting and writing the filesystem; a read-write mount or journal replay changes what you are trying to save.
- Image first, then save the metadata, read the files out of the image, and only then repair a copy of the image or the image itself.
- Run the read-only check before any repair; its exit status and messages decide which branch applies.
- ext4 branch: `e2fsck -fn` exit 0 is clean, 4 means errors left uncorrected; a dead primary superblock shows `bad magic number in super-block`.
- btrfs branch: `btrfs restore` reads files out without mounting and needs no root on an image file.

## Inspect selection

Symptom only: no health or partition-table signal shows a deletion.

## Register cases

- no register case yet

## Steps

1. Make a forensic image before attempting repair.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue --force '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be imaged read-only into the named scratch image?
   Stop and use a lab: Stop for a lab if the drive clicks, resets, disappears, or read errors grow quickly.

2. Create the output directories for saved metadata and read-out files.
   Tool: `mkdir` — catalog: host (base system)
   Command: `mkdir -p '{output}/readout'`
   Stop and use a lab: Stop if the output directory is on the disk being recovered.

3. ext4: save the filesystem metadata (QCOW2) from the image as evidence.
   Tool: `e2image` — catalog: e2image metadata image (ext4); route pacman:e2fsprogs; writes: yes
   Command: `e2image -Q '{image}' '{output}/metadata.qcow2'`
   Only when: `ext4_primary_ok`
   Stop and use a lab: Stop for a lab if e2image cannot read the superblock; go to the backup-superblock branch.

4. ext4: read-only check; exit 4 lists errors without changing the image.
   Tool: `e2fsck` — catalog: e2fsck read-only check (ext4); route pacman:e2fsprogs; writes: no
   Command: `e2fsck -fn '{image}'`
   Only when: `ext4_primary_ok`
   Stop and use a lab: Stop for a lab if errors are numerous or the check itself reports I/O errors.

5. ext4: read the files out of the damaged filesystem before any repair.
   Tool: `debugfs` — catalog: debugfs (ext4); route pacman:e2fsprogs; writes: yes
   Command: `debugfs -R 'rdump / {output}/readout' '{image}'`
   Only when: `ext4_primary_ok`
   Stop and use a lab: Stop for a lab if debugfs cannot open the filesystem or names too few files.

6. ext4: repair the image with an undo file so the repair can be reverted.
   Tool: `e2fsck` — catalog: e2fsck repair (ext4); route pacman:e2fsprogs; writes: yes
   Command: `e2fsck -fy -z '{output}/e2fsck.e2undo' '{image}'`
   Only when: `ext4_primary_ok`
   OWNER DECISION REQUIRED:
   Ask the owner: May e2fsck -fy repair this disk (with an undo file) after the image and read-out are saved?
   Stop and use a lab: Stop for a lab if the check cannot complete or the read-out already lost files.

7. ext4: confirm the backup superblock is readable (primary lost: `bad magic number`).
   Tool: `dumpe2fs` — catalog: e2fsck read-only check (ext4); route pacman:e2fsprogs; writes: no
   Command: `dumpe2fs -h -o 'superblock={backup_sb}' -o 'blocksize={blocksize}' '{image}'`
   Only when: `ext4_primary_lost`
   Stop and use a lab: Stop for a lab if no backup superblock answers; the block size and group size are guesses.

8. ext4: read the files out through the backup superblock before any repair (-c: catastrophic mode skips the stale bitmaps).
   Tool: `debugfs` — catalog: debugfs (ext4); route pacman:e2fsprogs; writes: yes
   Command: `debugfs -c -s '{backup_sb}' -b '{blocksize}' -R 'rdump / {output}/readout' '{image}'`
   Only when: `ext4_primary_lost`
   Stop and use a lab: Stop for a lab if debugfs cannot open the filesystem through the backup.

9. ext4: repair from the backup superblock with an undo file.
   Tool: `e2fsck` — catalog: e2fsck repair (ext4); route pacman:e2fsprogs; writes: yes
   Command: `e2fsck -fy -b '{backup_sb}' -B '{blocksize}' -z '{output}/e2fsck-backup.e2undo' '{image}'`
   Only when: `ext4_primary_lost`
   OWNER DECISION REQUIRED:
   Ask the owner: May e2fsck -fy -b rewrite this disk's superblock and descriptors from a backup copy?
   Stop and use a lab: Stop for a lab if e2fsck exits with 8 or more, or reports the backup superblock is also bad.

10. ext4: confirm the repaired image is clean.
   Tool: `e2fsck` — catalog: e2fsck read-only check (ext4); route pacman:e2fsprogs; writes: no
   Command: `e2fsck -fn '{image}'`
   Only when: `ext4_primary_lost`
   Stop and use a lab: Stop for a lab if the check still reports errors.

11. btrfs: read-only check of the image.
   Tool: `btrfs check` — catalog: btrfs check read-only (btrfs); route pacman:btrfs-progs; writes: no
   Command: `btrfs check --readonly '{image}'`
   Only when: `btrfs`
   Stop and use a lab: Stop for a lab if check cannot open the filesystem.

12. btrfs: read the files out without mounting.
   Tool: `btrfs restore` — catalog: btrfs restore (btrfs); route pacman:btrfs-progs; writes: no
   Command: `btrfs restore -i '{image}' '{output}/readout'`
   Only when: `btrfs`
   Stop and use a lab: Stop for a lab if restore cannot find a tree root; try a superblock mirror first.

13. btrfs: read the files out through the first superblock mirror (primary lost).
   Tool: `btrfs restore` — catalog: btrfs restore (btrfs); route pacman:btrfs-progs; writes: no
   Command: `btrfs restore -i -u 1 '{image}' '{output}/readout'`
   Only when: `btrfs_primary_lost`
   Stop and use a lab: Stop for a lab if no mirror answers.

14. btrfs: rewrite the primary superblock from a good mirror.
   Tool: `btrfs rescue super-recover` — catalog: btrfs rescue (btrfs); route pacman:btrfs-progs; writes: yes
   Command: `btrfs rescue super-recover -y '{image}'`
   Only when: `btrfs_primary_lost`
   OWNER DECISION REQUIRED:
   Ask the owner: May btrfs rescue super-recover rewrite this disk's primary superblock from a mirror?
   Stop and use a lab: Stop for a lab if no mirror is good; never run btrfs check --repair first.

