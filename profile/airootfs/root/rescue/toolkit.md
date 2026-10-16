# The stick's repair toolkit

Every command below is on this live system and works without a network.
Use these before anything else, and never install a package from the network
into the live system for a job this list covers. A tool that works inside the
machine's own root (its package manager, its initramfs generator) runs there,
in the chroot; the copies here are for when the machine's own are broken or
missing. The guardrails in AGENTS.md decide which of these you may run and
when: this list grants nothing.

Each single word in backticks below is a command; `tests/qemu-boot.sh`
checks that every one of them resolves on the built image.

## Disk health and imaging

- SMART and device state: `smartctl`, `nvme`, `hdparm`, `sdparm`, `sg_inq`, `lsscsi`.
- Surface reads: `badblocks` (read-only mode only).
- Imaging a failing disk to another disk the owner names: `ddrescue`, and `dd_rescue` for a source that `ddrescue` cannot read.
- Recovering deleted files from an image or a read-only device: `foremost` (carves by file signature; write its output under `/root` or to a disk the owner names).
- Filesystem forensics, read-only: `fls`, `icat`, `istat`, `fsstat`, `mmls`, `tsk_recover`.
- The drive's own settings: `idle3ctl` reads a drive's idle3 timer (`-g`); changing it (`-s`, `-d`) is a lasting change that needs the owner's OK on screen, as rule 4 asks for other lasting changes.
- Firmware and device state: `fwupdmgr` and `fwupdtool`, to read only (`fwupdmgr get-devices`, `fwupdmgr get-updates`, `fwupdmgr get-history`, `fwupdmgr security`). Updating firmware is the owner's lasting change; never do it.
- Filesystem-aware images and archives: `partclone.ext4`, `partclone.vfat`, `partclone.btrfs`, `partclone.ntfs`, `fsarchiver`, `ntfsclone`.
- Block devices: `lsblk`, `blkid`, `blockdev`, `findmnt`.
- Looking for a signature on a raw disk or partition: `wipefs -n`, `blkid -p`,
  `testdisk`, or a bounded read (`dd if=<dev> bs=1M skip=<n> count=<n> | grep -abo …`).
  Never point `grep`, `strings` or `xxd` at a whole device: on a disk of
  zeros `grep -a` holds the whole disk as one line, and the command does
  not come back.

## Partition tables

- Read and rebuild: `sfdisk`, `sgdisk`, `gdisk`, `parted`, `partprobe`.
- Lost partitions: `testdisk`, `gpart`.

## Filesystems

- btrfs: `btrfs`, `btrfstune`.
- ext2/3/4: `e2fsck`, `dumpe2fs`, `debugfs`, `tune2fs`, `resize2fs`.
- XFS: `xfs_repair`, `xfs_db`, `xfs_admin`, `xfsdump`, `xfsrestore`.
- F2FS: `fsck.f2fs`.
- FAT and the ESP: `fsck.fat`, `mkfs.fat`, `fatlabel`, `fatresize`, `mdir`, `mcopy`.
- exFAT: `fsck.exfat`.
- NTFS: `ntfsfix`, `ntfsinfo`, `ntfslabel`, `ntfs-3g`.
- bcachefs: `bcachefs`.

## LVM, RAID and encryption

- LVM: `pvs`, `vgs`, `lvs`, `vgscan`, `vgchange`, `lvchange`, `thin_check`.
- Software RAID: `mdadm`.
- LUKS and BitLocker: `cryptsetup` (through `rescue-unlock` for a passphrase), `dmsetup`.

## Boot loaders, EFI variables and Secure Boot

- systemd-boot and UKIs: `bootctl`, `kernel-install`, `ukify`.
- GRUB: `grub-install`, `grub-mkconfig`, `os-prober`.
- rEFInd: `refind-install`.
- Firmware boot entries and variables: `efibootmgr`, `efivar`.
- Secure Boot state and keys: `mokutil`, `sbctl`, `sbverify`, `sbsign`, `efi-readvar`.
- Initramfs, for a chroot whose own generator is missing: `mkinitcpio`, `dracut`.
- Chroots: `arch-chroot`, `chroot`.

## Packages for the machine, without a network

- The stick's offline repository of Arch's packages: `rescue-repo` makes it
  readable at `/run/rescue-repo`; compare versions with `vercmp`. How to use
  it is in playbooks.md, "Packages without a mirror". It may come from past
  the image on the stick, and it may be absent: then `rescue-repo` says so
  and the stick works online only.

## Windows

- Mount and repair NTFS: `ntfs-3g`, `ntfsfix`.
- Registry hives (read them; edit only with the owner's OK): `hivexsh`, `hivexregedit`, `chntpw`.
- Windows images (`.wim`): `wimlib-imagex`.
- BitLocker volumes: `cryptsetup` (`--type bitlk`, read-only, with the recovery key the owner types).

## Bringing a network up

- The owner's network menu (a phone's USB tethering, a static address, Wi-Fi): `rescue-network`, which the owner runs in a window of their own, since Wi-Fi passwords are typed there and never reach you; it starts by itself before you do when no address arrives.
- State and addresses: `ip`, `networkctl`, `resolvectl`, `ethtool`, `ping`.
- Wired DHCP by hand: `dhcpcd`.
- Wi-Fi: `iwctl` (iwd), `wpa_supplicant`, `wpa_cli`, `iw`.
- Mobile broadband and modems: `mmcli` (ModemManager), `pppd`, `usb_modeswitch`.
- Phone tethering: Android USB tethering appears as a wired NIC (the kernel's rndis_host and cdc_ether drivers); an iPhone needs `usbmuxd` and pairing with `idevicepair`.

## Hardware and processes

- `dmesg`, `journalctl`, `lspci`, `lsusb`, `dmidecode`, `strace`, `htop`.
