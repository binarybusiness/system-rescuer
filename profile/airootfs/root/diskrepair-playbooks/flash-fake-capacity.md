# Fake-capacity flash media

Slug: `flash-fake-capacity`

## Triage

- `inspect` cannot detect this: the device reports the announced capacity and a plain read works. Suspect it when a USB stick or SD card is far cheaper than its label, or files written near the end come back corrupt or as copies of earlier files.
- Probe it with f3 (Fight Flash Fraud, github.com/AltraMayor/f3): `f3probe` writes test blocks and restores them in its default mode, so it touches the medium and needs the owner's decision on that device; `--destructive` skips the restore and loses any data. Image the medium first when it holds files that matter: the image holds only what is really stored.
- The probe reports the real capacity and the fake type (limbo, wraparound, chain). Data written past the real capacity is lost or overwritten, not stored.
- `f3fix` rewrites the partition table to the real capacity: it writes to the medium and is an owner decision. After it, `f3write` and `f3read` fill and check the new filesystem to confirm.
- The real capacity is a fact about the device, not a repair: return the device or use it only at its real size. Stop here; diskrepair's commercial price list names no recovery-lab or firmware-lab option for a counterfeit, because nothing is broken to repair.

## Inspect selection

Symptom only: inspect cannot detect fake capacity. Choose it by symptom with `diskrepair playbook 'fake capacity'`.

## Register cases

- no register case yet

## Steps

1. Probe the real capacity and the type of fake. Non-destructive mode writes test blocks and restores them.
   Tool: `f3probe` — catalog: f3probe; route aur:f3; writes: yes
   Command: `f3probe --time-ops --show-progress=0 '{device}'`
   On the rescue stick: unavailable on the rescue stick (f3 is AUR, not on the stick); use another Linux machine with f3
   OWNER DECISION REQUIRED:
   Ask the owner: May f3probe write test blocks to this flash device and restore them (non-destructive mode)? The device must be unmounted.
   Stop and use a lab: Stop and return the device if it is counterfeit; do not store data past the usable size.

2. Rewrite the partition table to cover only the real capacity, using the last sector f3probe printed.
   Tool: `f3fix` — catalog: f3fix; route aur:f3; writes: yes
   Command: `f3fix '--last-sec={last_sec}' '{device}'`
   On the rescue stick: unavailable on the rescue stick (f3 is AUR, not on the stick); use another Linux machine with f3
   OWNER DECISION REQUIRED:
   Ask the owner: May this flash device's partition table be rewritten to the probed real size (f3fix)? Existing partitions on it are replaced.
   Stop and use a lab: Stop and return the device if f3fix cannot create the partition.

3. Make a filesystem on the new partition.
   Tool: `mkfs.vfat` — catalog: fsck.fat repair (vfat); route pacman:dosfstools; writes: yes
   Command: `mkfs.vfat '{partition}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May a FAT filesystem be created on the new partition of this flash device? Its contents are destroyed.
   Stop and use a lab: Stop and return the device if the filesystem cannot be created.

4. Mount the partition.
   Tool: `mount` — catalog: host (base system)
   Command: `mount '{partition}' '{mountpoint}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May the new partition of this flash device be mounted for the f3write and f3read check?
   Stop and use a lab: Stop and return the device if it will not mount.

5. Fill the mounted filesystem with f3write test files.
   Tool: `f3write` — catalog: f3write and f3read; route aur:f3; writes: yes
   Command: `f3write --show-progress=0 '{mountpoint}'`
   On the rescue stick: unavailable on the rescue stick (f3 is AUR, not on the stick); use another Linux machine with f3
   OWNER DECISION REQUIRED:
   Ask the owner: May f3write fill the mounted filesystem of this flash device with test files?
   Stop and use a lab: Stop and return the device if the writes fail partway.

6. Read the test files back and check them.
   Tool: `f3read` — catalog: f3write and f3read; route aur:f3; writes: yes
   Command: `f3read --show-progress=0 '{mountpoint}'`
   On the rescue stick: unavailable on the rescue stick (f3 is AUR, not on the stick); use another Linux machine with f3
   Stop and use a lab: Stop and return the device if f3read reports corrupted or overwritten sectors.

7. Unmount the partition.
   Tool: `umount` — catalog: host (base system)
   Command: `umount '{mountpoint}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May the flash device's partition be unmounted after the f3 check?
   Stop and use a lab: Stop if it stays busy; do not unplug the device while mounted.

