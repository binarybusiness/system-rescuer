# Playbooks: boot-chain repairs and failure patterns

Reference for `AGENTS.md`. The guardrails there apply to every command here;
commands marked **OK** need the owner's on-screen OK first.

## Getting into the installed system

- Every disk is read-only at the block layer until you run `blockdev --setrw
  /dev/<disk>` for a repair that writes it (rule 1); mount read-only until
  then, and remount read-write (`mount -o remount,rw`) after it.
- Most distributions: mount root (and `/boot`, the ESP, and any separate
  `/boot/efi` per its fstab) under `/mnt/target`, then `arch-chroot
  /mnt/target`. It bind-mounts `/dev`, `/proc`, `/sys`, efivars and
  resolv.conf for you.
- btrfs roots: find the root subvolume (`btrfs subvolume list`, the
  `rootflags=subvol=` in the loader entry) and mount with `-o subvol=<name>`.
- LUKS: `rescue-unlock <dev> <name>`, the owner typing the passphrase (rule 6);
  LVM: `vgchange -ay`; md RAID: `mdadm --assemble --scan` (assemble only).
- NixOS has no `/bin/bash`: mount the root read-write (the boot loader
  installer writes `/etc/kernel/entry-token`, and fails halfway on a
  read-only root) and the ESP at `/mnt/target/boot`, bind-mount `/dev`,
  `/proc`, `/sys`, `/sys/firmware/efi/efivars` yourself and
  `chroot /mnt/target /nix/var/nix/profiles/system/sw/bin/bash`.

## Rebuilding the boot chain, per distribution

Find the initramfs generator first: `mkinitcpio`, `dracut` or `booster`
config in `/etc`, and which boot loader the ESP holds.

| Distribution | Initramfs | Boot loader |
|---|---|---|
| Arch, Manjaro | `mkinitcpio -P` (missing kernel file: **OK** `pacman -S linux` from the cache, or from the stick without a mirror: below) | systemd-boot `bootctl install`; GRUB `grub-install --target=x86_64-efi --efi-directory=<esp> --bootloader-id=<id>` then `grub-mkconfig -o /boot/grub/grub.cfg` |
| EndeavourOS | `dracut-rebuild` (dracut), or mkinitcpio on older installs | systemd-boot entries via `reinstall-kernels`; GRUB as Arch |
| Debian, Ubuntu | `update-initramfs -u -k all` | `grub-install` then `update-grub`; after an interrupted upgrade **OK** `dpkg --configure -a` |
| Fedora, RHEL | `dracut -f --regenerate-all` | BLS entries in `/boot/loader/entries`; `grub2-mkconfig -o /boot/grub2/grub.cfg` |
| openSUSE | `dracut -f --regenerate-all` | `update-bootloader --reinit` |
| NixOS | from the generation | `NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot`, which also writes `loader.conf`'s `default`; when it fails, fix the cause and run it again rather than copying boot files by hand; an older generation boots from the systemd-boot menu |

A firmware boot entry that has vanished (after a firmware reset or update) is
restored by the loader's install command, or by `efibootmgr --create --disk
<disk> --part <n> --loader '\EFI\...\x.efi' --label <name>`.

## Packages without a mirror

When a package's own files are broken (a kernel update cut off while pacman
wrote them: a 0-byte `vmlinuz` under `/usr/lib/modules`, modules missing),
rebuilding the boot files is not enough, and the package must be installed
again. When the machine's mirrors cannot be reached, the stick carries an
offline repository of Arch's packages from the day it was built: linux,
linux-lts, linux-firmware, mkinitcpio, dracut, systemd, grub, efibootmgr and
base, with everything they depend on, at `/run/rescue-repo` (run `rescue-repo`
if it is missing). It serves Arch-family machines (Arch, EndeavourOS) only.

1. Compare versions: the machine's (`pacman --root <root> -Q <pkg>`) with the
   file name in `/run/rescue-repo` (`vercmp <stick> <machine>`). When the
   machine's is newer, do not downgrade: record both versions in the log and
   tell the owner in the HANDBACK which package to fetch when the network is
   back.
2. **OK** Bind the repository into the root read-only and install the file
   there, so the package's hooks rebuild the boot files:
   `mkdir -p <root>/mnt/rescue-repo && mount --bind -o ro /run/rescue-repo <root>/mnt/rescue-repo`,
   then in the chroot `pacman -U /mnt/rescue-repo/<file>.pkg.tar.zst`; a
   stale `/var/lib/pacman/db.lck` from the cut-off update goes first, once no
   pacman runs. Unmount it afterwards.
3. Verify: `pacman --root <root> -Qkk <pkg>` reports no missing or altered
   files, and the boot files are back on the ESP.

## Failure patterns: evidence → cause → repair

- **Interrupted update or power loss while writing boot files.** Kernel or
  initramfs on the ESP missing or 0 bytes, FAT dirty bit set, the package or
  rebuild log ends mid-transaction, the last boot's journal stops without a
  shutdown. → **OK** `fsck.vfat -a` on the backed-up ESP, then rebuild the
  boot chain for the installed generation or kernel.
- **ESP or /boot full.** `df` near 100%, many old kernels or generations. →
  Remove old kernels the package manager no longer references, or, with an
  **OK**, prune old generations; never delete the running set. A NixOS
  switch that ran out of space leaves the new generation in the profile with
  no boot entry, and a partial `*.tmp.` copy on the ESP that its next run
  removes.
- **UUID mismatch.** A disk was replaced, cloned or reformatted: the UUIDs in
  fstab, the loader entries or `/etc/crypttab` do not exist in `blkid`. →
  Correct the reference (back up the file first), rebuild the initramfs.
- **Storage controller mode changed** (IDE↔AHCI, RAID, Intel VMD), or the
  disk moved to another controller or machine. The initramfs lacks the driver
  (`ahci`, `vmd`, `nvme`, `virtio_scsi`; list it with `lsinitcpio` or
  `lsinitrd`), often because an autodetecting generator (mkinitcpio's
  `autodetect` hook, dracut's host-only mode) built it on the old hardware;
  the kernel cannot find root. → Rebuild the initramfs in the chroot on this
  machine, or add the module to its configuration first; or set the firmware
  mode back.
- **Firmware boot entries lost** (a mainboard swap, CMOS reset or firmware
  update) and no fallback `\EFI\BOOT\BOOTX64.EFI` on the ESP: the firmware
  finds nothing to boot. `efibootmgr -v` lists no entry for the disk's loader.
  → Reinstall the boot loader (`bootctl install`, `grub-install`), which
  writes the loader, the fallback copy where it does so, and the entry. With
  Windows on the machine, see "Linux and Windows on one machine" below.
- **A disk in fstab is gone.** The boot waits 90 s ("Timed out waiting for
  device", "Dependency failed for /srv/…") and ends in the emergency shell;
  the UUID is in no `blkid` output. → If booting does not need the disk, add
  `nofail` to its line (back up fstab first), keep the line, and log which
  disk is missing.
- **Degraded RAID or btrfs pool** (a member missing or failed). `btrfs
  filesystem show` reports missing devices, `mdadm --detail` a degraded
  array. Never `btrfs check --repair`, `btrfs replace`, a balance or an
  array rebuild: those are the owner's, with a new disk. Look at the data
  read-only at most (`mount -o ro,degraded`); if booting waits for the pool,
  add `nofail` to its fstab line; name the missing member for the owner.
- **Unclean or damaged filesystem.** fsck -n reports errors, mount fails or
  is read-only. → **OK** repairing fsck; check SMART first (rule 2).
- **Partition table gone** (a disk shows no partitions: `lsblk` lists none,
  `sfdisk -d` finds no table, firmware has nothing to boot). → Find the old
  layout read-only first: `gdisk -l` (a surviving backup GPT header),
  `testdisk /list <disk>` and filesystem signatures at their offsets; save
  what you found to `/root` and show it to the owner. Writing the table back
  needs **OK**, and writes only the table, never the partitions' contents:
  after `blockdev --setrw` of that disk (rule 1), recreate the table with a
  partition tool, for example `sfdisk <disk> < /root/layout` where the layout
  has `label: gpt`, the old `label-id`, and each partition's `start`, `size`,
  `type`, `uuid` and `name` as the surviving entries show them (`gdisk -l`,
  `testdisk`, or the entry array at LBA 2 when only the signatures are
  gone), or testdisk's Write. Never patch signatures or headers with `dd`,
  not even a few bytes (rule 5).
- **Failing disk.** SMART failing, pending or reallocated sectors rising, I/O
  errors in dmesg. → No repair on it: image with `ddrescue` to another disk.
- **Kernel or driver update broke boot** (graphics, out-of-tree modules). →
  Boot the previous or fallback entry; reinstall or pin the old kernel.
- **Root filesystem full.** Services fail, login loops. → Before clearing
  anything, log a DIAGNOSIS line naming the largest directories (`du -xh -d 3`
  on the mounted root), even when an interrupted download or the package cache
  explains the last blocks: the owner needs to know what will fill it again.
  Clearing the package cache, a partial download or `journalctl --vacuum-size`
  needs **OK**; never delete user data.
- **Secure Boot rejects the loader** (firmware message about a signature). →
  Report it; the owner disables Secure Boot or enrols the key in firmware.

## When the network fails during a rescue

A package download or the model's answers failing mid-rescue point at this
live system's network, not the machine's disks. Check, read-only, in this
order: links and addresses (`ip -brief link`, `ip -brief address`), the
default route (`ip route`), DNS (`resolvectl query archlinux.org`), and the
route to the model API (`curl -sS -o /dev/null -w '%{http_code}\n'
https://$(sed -n 's/^host=//p' /etc/rescue/provider.conf)`, which needs no key and answers even without one).
Then say on screen, in plain words, what the owner must do: plug in or
reseat the cable, turn on the phone's USB tethering, or run `rescue-network`
in a new window (Ctrl-b c) for Wi-Fi or a static address. Never change this
live system's network configuration yourself, and never ask for or type a
Wi-Fi passphrase: the owner types it at `iwctl`'s own prompt in that menu,
where you cannot read it.

## Linux and Windows on one machine

**Where things are.** Windows' boot files live on an ESP under
`\EFI\Microsoft\Boot\` (`bootmgfw.efi` and the `BCD` store): on the Linux ESP
when Windows came first and Linux was installed beside it, or on an ESP of
Windows' own disk. Its system is on an NTFS partition (`blkid` TYPE `ntfs`,
`Windows\System32` inside), or BitLocker-encrypted (`blkid` TYPE `BitLocker`,
or `-FVE-FS-` at byte 3 of the partition). `efibootmgr -v` shows each entry's
partition as `HD(<n>,GPT,<PARTUUID>,…)`; match it against `blkid -s PARTUUID`.
An entry whose PARTUUID no disk has belongs to a disk that is not attached:
it is stale, not broken, and the firmware skips it.

**Symptoms**, from the owner's account more than from the disks:
- *Only Windows starts*: Linux's firmware entry is gone or behind Windows
  Boot Manager in `BootOrder` (a Windows update, a firmware reset), or the
  entries are gone and the fallback `\EFI\BOOT\BOOTX64.EFI` is Windows' loader
  (Windows copies it there).
- *Only Linux starts*: Windows' firmware entry is gone, or the Linux boot menu
  that would offer Windows is hidden: systemd-boot with `timeout 0` (or none)
  in `loader/loader.conf` boots its default at once, though it lists Windows
  on the same ESP by itself; GRUB without an os-prober entry for Windows.

When Linux's own boot chain is intact and the owner says a system is
missing, this is the fault: walk the firmware entries and the menu for each
installed system, not only for Linux.

The repair is done only when **each installed system has a firmware entry of
its own** (Windows' too, when the owner only missed Linux) and the owner can
choose it. The entries the firmware makes for a disk by itself (titled after
the disk, such as `UEFI <disk model>`, with no `HD(…)/File(…)` path) start
only that disk's fallback loader and do not count: once Linux's entry comes
first, a Windows reached only through one of them is lost to the owner.
A system is installed when the owner says so or its boot files are on an ESP
(for Windows, `\EFI\Microsoft\Boot\bootmgfw.efi`); do not judge from a look
at its partition that it is not real or not worth an entry. To look inside
NTFS, mount it read-only (`ntfs-3g -o ro`) and use `ls`; `ntfsls` reads a
directory only with `-p <dir>` and marks directories only with `-F`.

**A hibernated Windows.** Before you mount Windows' NTFS partition, and in
any case once you know Windows is installed, find out whether it is
hibernated: `ntfscat /dev/<part> hiberfil.sys | head -c 4` reads without
mounting, and `HIBR` or `hibr` there means Windows was hibernated or shut
down with Fast Startup, the owner's open work saved in `hiberfil.sys`
(`ntfs-3g.probe --readwrite` says the same, exit 14, but only on a disk
that is writable). Log it as a finding, tell the owner that Windows will
resume as they left it, and do not mount that partition at all, nor run an
NTFS tool that writes to it: a Windows started after its hibernation was
removed loses that work. The repair of Linux's boot goes ahead as usual.

**Allowed** (it is booting, rule 8):
- Create a missing firmware entry: `efibootmgr --create --disk /dev/<disk>
  --part <n> --label "<label>" --loader '<path>'`, with the label and path the
  system uses (`Linux Boot Manager` and `\EFI\systemd\systemd-bootx64.efi`;
  `Windows Boot Manager` and `\EFI\Microsoft\Boot\bootmgfw.efi`). `--create`
  puts the new entry first; set the order afterwards.
- Set `BootOrder` (`efibootmgr -o`): Linux first and Windows next, unless the
  owner wants otherwise; keep every other entry in it, in its order.
- Linux-side menu settings: systemd-boot's `timeout` in `loader.conf` (a few
  seconds, backed up first, rule 3) or `bootctl set-timeout`; for GRUB,
  os-prober and `grub-mkconfig`.
- `bootctl install` only when systemd-boot's own files are missing: it also
  copies itself over `\EFI\BOOT\BOOTX64.EFI`, so keep a copy of what was
  there first; when the loader files are intact, create the entry instead.

**With an OK** (rule 4): copying Windows' boot files to another ESP (copy
only; the originals stay where they are, unchanged); and, while BitLocker is
on, any change to the firmware entries, the order or an ESP, since Windows
may then ask for its recovery key at its next start: say so in the question,
and tell the owner to have the key at hand.

**Never** (rule 5): edit the BCD (`bcdedit`, `hivex`, any write to it) or any
other file of Windows, on the ESP or on its own partitions; mount an NTFS or
BitLocker partition read-write (read-only only: `mount -o ro`, `ntfs-3g -o
ro`), and a hibernated one (above) not at all, nor run an NTFS tool that
writes (`ntfsfix`, `ntfsresize`, `ntfscp`, `ntfslabel` with a new label);
delete a firmware entry (`efibootmgr -B`, `bootctl remove`, removing a
`Boot####` variable), not even a stale one or one you made yourself. A stale
entry ahead of Windows Boot Manager makes BitLocker ask for its recovery key:
with BitLocker on, propose moving Windows Boot Manager ahead of it in the
order (an **OK**), and leave the entry itself.

**Verify** with `efibootmgr -v`: an entry of its own for each installed
system (`HD(…)/File(…)` to its loader), each on a partition that exists, in
the order agreed; for systemd-boot, `bootctl
list` shows Windows among its entries, and the menu waits (a timeout above 0)
when the machine has more than one system. Hand back with which entry or menu
item starts each system.

**When Windows itself is broken** (its `BCD` store missing, empty or
unreadable, its `bootmgfw.efi` gone, or Windows' own startup error, such as
0xc000000f, with Windows' firmware entry intact and no Linux fault behind it),
the repair is Windows' own, which you may not make (rule 5). Diagnose
read-only, write nothing to any disk, and hand back `unrepairable`, telling the
owner to start Windows' installation media or a recovery drive and choose
Repair your computer, Troubleshoot, Startup Repair; and if that fails, in its
Command Prompt, `bcdboot C:\Windows` (C: being the Windows partition there).
On a machine with no Linux root filesystem the log stays in `/root/rescue-log`
here: do not copy it to Windows' partitions, an ESP or any other disk.

Other systems (macOS, BSDs): diagnose read-only and report. Do not change
their boot files on the ESP, except as part of an ESP backup.
