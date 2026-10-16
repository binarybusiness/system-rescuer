# Deleted files

Slug: `deleted-files`

## Triage

- Stop using the filesystem immediately; new writes can overwrite deleted data.
- Image first, then recover only from the image into a separate output directory.

## Inspect selection

Symptom only: no health or partition-table signal shows a deletion.

## Register cases

- no register case yet

## Steps

1. Make a forensic image before attempting file recovery.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue --force '{device}' '{image}' '{output}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be imaged read-only into the named scratch image?
   Stop and use a lab: Stop for a lab if the drive clicks, resets, disappears, or read errors grow quickly.

2. Carve common file formats from the image into a separate output directory.
   Tool: `PhotoRec` — catalog: PhotoRec; route pacman:testdisk; writes: no
   Command: `photorec /d '{output}' /cmd '{image}' partition_none,fileopt,everything,disable,jpg,enable,png,enable,pdf,enable,search`
   Stop and use a lab: Stop for a lab if provenance, filenames, or directory structure are essential.

3. List deleted filesystem entries before extracting a chosen inode.
   Tool: `The Sleuth Kit fls` — catalog: The Sleuth Kit; route pacman:sleuthkit; writes: no
   Command: `fls -rd '{image}'`
   Stop and use a lab: Stop for a lab if the filesystem type or partition offset is unknown.

4. Extract a selected deleted inode to the separate output directory.
   Tool: `The Sleuth Kit icat` — catalog: The Sleuth Kit; route pacman:sleuthkit; writes: no
   Command: `icat -r '{image}' '{inode}'`
   Stop and use a lab: Stop for a lab if the inode has been reused or the extracted bytes are incomplete.

5. Attempt ext3/ext4 undelete only from the unmounted image.
   Tool: `extundelete` — catalog: extundelete; route aur:extundelete; writes: no
   Command: `extundelete --restore-all -o '{output}' '{image}'`
   On the rescue stick: PhotoRec or TestDisk's undelete (testdisk, on the stick)
   Stop and use a lab: Stop for a lab if journal history is needed or metadata is inconsistent.

6. Attempt NTFS undelete only from the image.
   Tool: `ntfsundelete` — catalog: ntfsundelete; route pacman:ntfsprogs; writes: no
   Command: `ntfsundelete -u -d '{output}' '{image}'`
   On the rescue stick: TestDisk's NTFS undelete (testdisk, on the stick)
   Stop and use a lab: Stop for a lab if the file is encrypted, compressed, or metadata is damaged.

