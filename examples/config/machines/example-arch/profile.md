# Machine profile: example-arch

An example profile for the qemu test disk that `tests/make-fixture.sh` builds
from it: an Arch Linux machine with systemd-boot and mkinitcpio, the ESP at
`/boot`. Write one like it for each machine you may need to rescue; the
agent reads it when `rescue-survey` finds one of the UUIDs in `match`.

## Disks — identify by UUID, never by name

| What | Identifier | Notes |
|---|---|---|
| Arch root | UUID `6b1d7c2e-0a4f-4c8e-9d3b-5e2f1a7c9d40`, ext4 | the only disk |
| ESP `/boot` | UUID `5E2F-1A7C`, vfat | systemd-boot, kernels and initramfs |

List here any disk the agent must not touch (a data pool, a backup disk),
by UUID or label.

## Repairing the boot chain

- The initramfs is built by mkinitcpio from `/etc/mkinitcpio.d/linux.preset`;
  from a chroot with the ESP mounted at `/boot`, `mkinitcpio -P` rebuilds it.
- Lasting configuration changes belong to the machine's owner: recommend them
  in the log.

## History

Past incidents and how they were repaired, newest first, help the agent
recognise a repeat.
