#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: the nixos-sdboot base recipe (the home server's shape): nixpkgs'
# make-disk-image builds a raw GPT disk (ESP at /boot with systemd-boot, ext4
# root) from a NixOS configuration with a serial console and a BOOT-OK
# service. The build runs in the nixos/nix container with /dev/kvm (the image
# is assembled in a VM), keeping its store in the docker volume
# system-rescuer-nix; no root on the build host, and nothing installed on it. The
# container uses the host network only to download (docker's bridge DNS
# fails on the build host); the VMs never do.
#
#   tests/spikes/base-nixos.sh        # as a user in the docker group
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

channel=${SPIKE_NIXOS_CHANNEL:-nixos-26.05}
work=$spike_tmp/nix
mkdir -p "$work"
cat > "$work/configuration.nix" <<'NIX'
{ pkgs, ... }: {
  networking.hostName = "spike-nixos";
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.loader.timeout = 0;
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
  boot.initrd.availableKernelModules = [ "ahci" "sd_mod" ];
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/ESP"; fsType = "vfat"; };
  systemd.services.boot-ok = {
    description = "Print BOOT-OK on the serial port";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    script = ''echo "BOOT-OK $(cat /etc/hostname)" > /dev/ttyS0'';
  };
  system.stateVersion = "25.05";
}
NIX
cat > "$work/image.nix" <<NIX
let
  nixpkgs = fetchTarball "https://nixos.org/channels/$channel/nixexprs.tar.xz";
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  nixos = import (nixpkgs + "/nixos") { configuration = ./configuration.nix; system = "x86_64-linux"; };
in import (nixpkgs + "/nixos/lib/make-disk-image.nix") {
  inherit pkgs;
  inherit (pkgs) lib;
  inherit (nixos) config;
  format = "raw";
  partitionTableType = "efi";
  installBootLoader = true;
  diskSize = "auto";
  additionalSpace = "512M";
}
NIX
start=$SECONDS
docker run --rm --network host --device /dev/kvm -v system-rescuer-nix:/nix -v "$work:/work" -w /work \
    -e NIX_CONFIG=$'extra-system-features = kvm\nsandbox = false' \
    nixos/nix sh -c "nix-build image.nix -o /tmp/result && cp -L /tmp/result/nixos.img /work/nixos.img && chmod 0644 /work/nixos.img && chown $(id -u):$(id -g) /work/nixos.img" \
    > "$work/build.log" 2>&1 || fail "nix build failed: $(tail -n 25 "$work/build.log")"
img=$work/nixos.img
pass "built the NixOS image in $((SECONDS - start)) s ($(du -h --apparent-size "$img" | cut -f1)); $(sfdisk -l "$img" | awk '/^\/.*img[0-9]/ {print $5, $6, $7}' | paste -sd ';' | sed 's/;/; /g')"

cp "$ovmf_vars" "$spike_tmp/vars.fd"
mapfile -t disk < <(ahci_disk "$img")
start=$SECONDS
qemu_ovmf "$spike_tmp/vars.fd" "$spike_tmp/serial.log" "${disk[@]}"
# The serial getty may print its login prompt first, on the same line.
wait_serial "$spike_tmp/serial.log" 'BOOT-OK spike-nixos' 180 \
    || fail "no BOOT-OK within 180 s; serial tail: $(tr -d '\r' < "$spike_tmp/serial.log" | tail -n 20)"
stop_qemu
pass "BOOT-OK on the serial port after $((SECONDS - start)) s"
# systemd-boot prints nothing with timeout 0; check the ESP holds it instead.
esp_start=$(sfdisk -J "$img" | jq '.partitiontable.partitions[] | select(.type == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B") | .start')
{ mdir -b -i "$img@@$((esp_start * 512))" ::/EFI/systemd ::/loader/entries > "$spike_tmp/esp.txt" 2>&1 \
    && grep -q 'systemd-bootx64.efi' "$spike_tmp/esp.txt"; } || fail "no systemd-boot on the ESP: $(cat "$spike_tmp/esp.txt")"
pass "the ESP holds systemd-boot and $(grep -c '\.conf$' "$spike_tmp/esp.txt") loader entries"
