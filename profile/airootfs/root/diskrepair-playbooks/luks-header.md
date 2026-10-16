# LUKS header damage

Slug: `luks-header`

## Triage

- Without an intact header or a header backup the data is unrecoverable: the master key lives only in the header.
- Image first, then take a header backup while the header is still readable, before anything is written.
- Try the least invasive restore first: `cryptsetup repair` fixes only benign damage; `luksHeaderRestore` needs a backup made from this exact volume.
- Prove recovery by opening the volume read-only and reading data back, not by the exit status of the restore.

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

2. Create the output directory.
   Tool: `mkdir` — catalog: host (base system)
   Command: `mkdir -p '{output}'`
   Stop and use a lab: Stop if the output directory is on the disk being recovered.

3. Back up the header while it is still readable (do this before any failure).
   Tool: `cryptsetup luksHeaderBackup` — catalog: cryptsetup luksHeaderBackup (LUKS); route pacman:cryptsetup; writes: no
   Command: `cryptsetup luksHeaderBackup '{image}' --header-backup-file '{backup}'`
   Only when: `header_readable`
   Stop and use a lab: Stop for a lab if luksDump already reports damage; do not overwrite an existing backup.

4. Show the header as evidence; a wiped header answers `is not a valid LUKS device`.
   Tool: `cryptsetup luksDump` — catalog: cryptsetup luksDump and isLuks (LUKS); route pacman:cryptsetup; writes: no
   Command: `cryptsetup luksDump '{image}'`
   Only when: `header_damaged`
   Stop and use a lab: Stop for a lab if the output names an unexpected LUKS version or no key slots.

5. Repair benign damage (a corrupt secondary header copy) in place.
   Tool: `cryptsetup repair` — catalog: cryptsetup repair (LUKS); route pacman:cryptsetup; writes: yes
   Command: `cryptsetup repair --batch-mode '{image}'`
   Only when: `header_damaged`
   OWNER DECISION REQUIRED:
   Ask the owner: May cryptsetup repair write this LUKS header?
   Stop and use a lab: Stop for a lab if repair reports it cannot fix the header; use the backup restore.

6. Restore the header from the pre-failure backup of this exact volume.
   Tool: `cryptsetup luksHeaderRestore` — catalog: cryptsetup luksHeaderRestore (LUKS); route pacman:cryptsetup; writes: yes
   Command: `cryptsetup luksHeaderRestore --batch-mode '{image}' --header-backup-file '{backup}'`
   Only when: `header_damaged`
   OWNER DECISION REQUIRED:
   Ask the owner: May cryptsetup luksHeaderRestore overwrite this disk's LUKS header from the named backup?
   Stop and use a lab: Stop for a lab if the backup is from another volume or the passphrase was changed since it was made.

7. Check the passphrase or key file against the header without mapping.
   Tool: `cryptsetup open` — catalog: cryptsetup luksDump and isLuks (LUKS); route pacman:cryptsetup; writes: no
   Command: `cryptsetup open --test-passphrase --key-file '{key}' '{image}'`
   Stop and use a lab: Stop for a lab if no key slot accepts the key.

8. Open the volume read-only.
   Tool: `cryptsetup open` — catalog: cryptsetup luksDump and isLuks (LUKS); route pacman:cryptsetup; writes: no
   Command: `cryptsetup open --readonly --key-file '{key}' '{image}' '{mapname}'`
   Stop and use a lab: Stop for a lab if the open fails after a restore.

9. Copy the mapped data out to the output directory.
   Tool: `dd` — catalog: host (base system)
   Command: `dd 'if=/dev/mapper/{mapname}' 'of={output}/luks-data.bin' bs=1M status=none`
   Stop and use a lab: Stop for a lab if dd reports read errors.

10. Close the mapping.
   Tool: `cryptsetup close` — catalog: cryptsetup luksDump and isLuks (LUKS); route pacman:cryptsetup; writes: no
   Command: `cryptsetup close '{mapname}'`
   Stop and use a lab: Stop if the mapping is busy.

