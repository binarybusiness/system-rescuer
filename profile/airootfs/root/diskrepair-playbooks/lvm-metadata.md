# LVM metadata loss

Slug: `lvm-metadata`

## Triage

- The data is intact; only the PV label and VG metadata are gone. Do not run pvcreate, vgcreate or lvcreate without --restorefile.
- Image first. A metadata backup (/etc/lvm/backup/<vg>, /etc/lvm/archive/, or a vgcfgbackup file) must name the PV UUID.
- Restrict every LVM command to the target with `--devices`, so it never scans other disks.
- Prove recovery by reading the logical volume back, not by the exit status of vgcfgrestore.

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

3. Save the VG metadata text while the VG is still visible (do this before any failure).
   Tool: `vgcfgbackup` — catalog: vgcfgbackup (LVM); route pacman:lvm2; writes: no
   Command: `vgcfgbackup --devices '{device}' -f '{backup}' '{vg}'`
   Only when: `vg_visible`
   Stop and use a lab: Stop for a lab if the VG reports missing PVs.

4. Show what the surviving metadata areas hold (the VG is not found).
   Tool: `pvck` — catalog: pvck dump (LVM); route pacman:lvm2; writes: no
   Command: `pvck --devices '{device}' --dump headers '{device}'`
   Only when: `metadata_lost`
   Stop and use a lab: Stop for a lab if no LVM label or metadata text is found.

5. Recreate the PV label with its original UUID from the metadata backup (no data is touched).
   Tool: `pvcreate` — catalog: vgcfgrestore (LVM); route pacman:lvm2; writes: yes
   Command: `pvcreate --devices '{device}' --yes --uuid '{pv_uuid}' --restorefile '{backup}' '{device}'`
   Only when: `metadata_lost`
   OWNER DECISION REQUIRED:
   Ask the owner: May pvcreate --uuid --restorefile write a PV label and metadata area on this disk?
   Stop and use a lab: Stop for a lab if the backup does not name this PV UUID or its size and extents differ.

6. Restore the VG metadata from the backup.
   Tool: `vgcfgrestore` — catalog: vgcfgrestore (LVM); route pacman:lvm2; writes: yes
   Command: `vgcfgrestore --devices '{device}' -f '{backup}' '{vg}'`
   Only when: `metadata_lost`
   OWNER DECISION REQUIRED:
   Ask the owner: May vgcfgrestore rewrite this disk's VG metadata from the named backup?
   Stop and use a lab: Stop for a lab if vgcfgrestore refuses or lists a different PV.

7. Activate the volume group.
   Tool: `vgchange` — catalog: vgcfgrestore (LVM); route pacman:lvm2; writes: yes
   Command: `vgchange --devices '{device}' -ay '{vg}'`
   Only when: `metadata_lost`
   OWNER DECISION REQUIRED:
   Ask the owner: May the volume group be activated on this device (vgchange -ay)? Activation can update LVM metadata.
   Stop and use a lab: Stop for a lab if activation reports missing extents.

8. Copy the logical volume out to the output directory.
   Tool: `dd` — catalog: host (base system)
   Command: `dd 'if=/dev/{vg}/{lv}' 'of={output}/lv-data.bin' bs=1M status=none`
   Only when: `metadata_lost`
   Stop and use a lab: Stop for a lab if dd reports read errors.

