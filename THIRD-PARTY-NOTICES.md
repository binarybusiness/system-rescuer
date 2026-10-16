# Third-party notices

system-rescuer is licensed under the GNU General Public License, version 3
or (at your option) any later version ([LICENSE](LICENSE)); every source
file says so in an `SPDX-License-Identifier` line, which
`tests/spdx-check.sh` checks, together with this project's holder line on owned
files. Project attribution is in [COPYRIGHT](COPYRIGHT); it applies to original
code and modifications, not third-party portions. This page lists what the repository and the
image it builds carry that others wrote, and under which terms.

## In the repository

### archiso's releng profile

`profile/` is derived from archiso's `releng` profile
(`/usr/share/archiso/configs/releng/` of the `archiso` package,
<https://gitlab.archlinux.org/archlinux/archiso>). archiso is licensed under
the terms of GPL-3.0-or-later, as its README says and as the profile's own
scripts state in their SPDX lines. The files taken from it unchanged or
nearly so (among them `profile/airootfs/usr/local/bin/choose-mirror`,
`livecd-sound` and `Installation_guide`, the boot loader configuration under
`profile/efiboot/`, `profile/grub/` and `profile/syslinux/`, and the base of
`profile/packages.x86_64`, `profile/pacman.conf` and `profile/profiledef.sh`)
keep archiso's copyright, held by its contributors (archiso's `AUTHORS.rst`).
The copied `choose-mirror`, `livecd-sound`, `Installation_guide` and
`profile/airootfs/root/.automated_script.sh` remain unchanged; the holder
check excludes those upstream files. Modified derived files such as
`profile/profiledef.sh` also identify this project's modifications.

### diskrepair's playbooks

`profile/airootfs/root/diskrepair-playbooks/` is copied byte-identical from
the export of diskrepair, the owner's disk-repair project
(`diskrepair export --for system-rescuer`), and is never edited here. Its
owner releases it under the GNU General Public License, version 3 or (at your
option) any later version, as the rest of this project.

### The rescue-carry-on plugin

`profile/airootfs/root/.config/opencode/plugins/rescue-carry-on/` is this
project's own code, under this project's licence. It is a plugin for
OpenCode's plugin interface and uses only Node's built-in modules
(`node:child_process`, `node:fs`); it contains no code from OpenCode.

### The Windows 11 evaluation automation

`tests/bench/win11/` (the unattended-install answer file and its setup and
boot scripts) is this project's own code, under this project's licence. It
automates an install of Microsoft's Windows 11 Enterprise evaluation, which
the repository neither contains nor downloads: `tests/win11-image.sh` takes
an ISO the user obtained from Microsoft's Evaluation Center, under
Microsoft's terms for it (for evaluation and testing, not production, for 90
days from installation).

## In the image

### OpenCode

The image installs OpenCode (<https://github.com/anomalyco/opencode>) from
Arch Linux's `opencode` package. It is licensed under the MIT License,
Copyright (c) 2025 opencode; its text is on the image at
`/usr/share/licenses/opencode/LICENSE`. The repository contains no OpenCode
code.

### Arch Linux packages

The image is assembled from Arch Linux's binary packages: those
`profile/packages.x86_64` lists, their dependencies, and the offline
repository's (`profile/offline-repo.x86_64`). Each package is under its own
licence, recorded in its metadata (`pacman -Qi`) and, for most, as a text in
`/usr/share/licenses/` on the image. The exact package list of a built
image is `arch/pkglist.x86_64.txt` on its ISO.

The repository distributes no image. Whoever distributes a built image
distributes those packages, and for the ones under the GPL or a similar
licence must offer their corresponding source. Arch Linux publishes each
package's build recipe at <https://gitlab.archlinux.org/archlinux/packaging/packages>
and its earlier binary versions at <https://archive.archlinux.org/>; a
published image's release notes name the package list and how to obtain the
sources.
