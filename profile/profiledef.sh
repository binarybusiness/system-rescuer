#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck disable=SC2034

iso_name="system-rescuer"
iso_label="RESCUE_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="system-rescuer"
iso_application="system-rescuer repair stick"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
# The live root's copy-on-write space (archiso's default is 256M): the brief
# keeps an ESP's raw image and tarball under /root, and auditd stops recording
# when the space fills.
kernel_params_x86_64="cow_spacesize=75%"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
  ["/root/.ssh"]="0:0:700"
  ["/root/.ssh/authorized_keys"]="0:0:600"
  ["/root/.config/rescue"]="0:0:700"
  ["/root/.config/rescue/deepseek-key"]="0:0:600"
  ["/usr/local/bin/rescue-agent"]="0:0:755"
  ["/usr/local/bin/rescue-agent-start"]="0:0:755"
  ["/usr/local/bin/rescue-hang-watch"]="0:0:755"
  ["/usr/local/bin/rescue-identities"]="0:0:755"
  ["/usr/local/bin/rescue-keycheck"]="0:0:755"
  ["/usr/local/bin/rescue-proxy-conf"]="0:0:755"
  ["/usr/local/bin/rescue-secrets"]="0:0:755"
  ["/usr/local/bin/rescue-unlock"]="0:0:755"
  ["/usr/local/bin/rescue-network"]="0:0:755"
  ["/usr/local/bin/rescue-survey"]="0:0:755"
  ["/usr/local/bin/rescue-repo"]="0:0:755"
)
