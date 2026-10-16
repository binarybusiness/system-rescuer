# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's base_load, which sets bench_tmp
# nixos-sdboot: NixOS 26.05 with systemd-boot and an ext4 root, the ESP at
# /boot, in the home server's shape (no configurationLimit). The interface is in
# tests/base-image.sh.
base_summary="NixOS, systemd-boot, ext4 root, five generations"
base_esp=/boot
base_initramfs=nixos
base_loader=systemd-boot
base_recipe=(build_nixos)
base_build() { build_nixos "$1" nixos-sdboot; }

# build_nixos <image> <hostname>: as root, nixpkgs' make-disk-image builds a
# raw GPT disk (a 248 MiB ESP labelled ESP at /boot, an ext4 root labelled
# nixos) in the nixos/nix container with /dev/kvm, its store kept in the
# docker volume system-rescuer-nix (the container uses the host
# network only to download, the VMs never). The installed system is
# generation 1. Its first boot (the bench-first-boot unit, which plays the
# installer's part as lib.sh's does on the other bases) adds generations 2 to
# 4, variants whose initrds each carry 28 MiB of incompressible padding, as
# kernel updates would, then the system itself again as generation 5, the
# current one; installs the boot loader, registering it in the firmware as
# canTouchEfiVariables does; and lists the variants that scenarios switch to
# in /var/lib/bench/generations ("a2-next <toplevel>": /etc only, sharing the
# kernel; "a3-next <toplevel>": another padded initrd). The ESP's size
# leaves room for one more unpadded initrd (27 MB, as A2's repair needs) but
# not for a padded one (57 MB, as A3's switch needs): the kernel is 14 MB and
# the five generations' boot files take 211 MB of its 256.
build_nixos() {
    local img=$1 host=$2 work=$bench_tmp/nix
    mkdir -p "$work"
    cat > "$work/common.nix" <<NIX
{ pkgs, ... }: {
  networking.hostName = "$host";
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0;
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200" ];
  boot.initrd.availableKernelModules = [ "ahci" "sd_mod" ];
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-label/ESP"; fsType = "vfat"; options = [ "fmask=0077" "dmask=0077" ]; };
  documentation.enable = false;
  systemd.services.boot-ok = {
    description = "Print BOOT-OK on the serial port";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    serviceConfig.Type = "oneshot";
    # On a line of its own: the serial getty's login prompt can come first.
    script = ''printf '\nBOOT-OK %s\n' "\$(cat /etc/hostname)" > /dev/ttyS0'';
  };
  system.stateVersion = "26.05";
}
NIX
    # A variant: the common system with its name in /etc and, when padded, an
    # initrd with a cpio archive of incompressible bytes prepended.
    cat > "$work/variant.nix" <<'NIX'
{ name, pad }: { pkgs, lib, ... }: {
  imports = [ ./common.nix ];
  environment.etc."bench-generation".text = "${name}\n";
  boot.initrd.prepend = lib.optional pad "${pkgs.runCommand "bench-initrd-pad-${name}" { nativeBuildInputs = [ pkgs.cpio pkgs.openssl ]; } ''
    mkdir -p root/bench && cd root
    head -c 29360128 /dev/zero | openssl enc -aes-128-ctr -nosalt -pbkdf2 -pass pass:${name} > bench/pad
    find . | cpio --quiet -o -H newc > $out
  ''}";
}
NIX
    cat > "$work/image.nix" <<'NIX'
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/7993f34ee47e28a3d607a525aadc6c94b73be728.tar.gz";
    sha256 = "1gdy838s9vsjsd1lqq746a597fqrgvqqpmnzs07fl0vksskbfsk4";
  };
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  eval = configuration: import (nixpkgs + "/nixos") { inherit configuration; system = "x86_64-linux"; };
  variant = name: pad: (eval (import ./variant.nix { inherit name pad; })).config.system.build.toplevel;
  older = map (n: variant "gen${toString n}" true) [ 2 3 4 ];
  a2 = variant "a2-next" false;
  a3 = variant "a3-next" true;
  base = eval ({ pkgs, ... }: {
    imports = [ ./common.nix ];
    systemd.services.bench-first-boot = {
      description = "Make the generations and install the boot loader on the first boot";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" "boot-ok.service" ];
      unitConfig.ConditionPathExists = "!/var/lib/bench-first-boot";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.nix pkgs.coreutils pkgs.systemd ];
      script = ''
        exec > /dev/ttyS0 2>&1
        set -x
        p=/nix/var/nix/profiles/system
        self=$(readlink -f /run/current-system)
        for g in ${toString older}; do nix-env -p $p --set $g; done
        nix-env -p $p --set $self
        NIXOS_INSTALL_BOOTLOADER=1 $p/bin/switch-to-configuration boot
        mkdir -p /var/lib/bench
        printf 'a2-next %s\na3-next %s\n' ${a2} ${a3} > /var/lib/bench/generations
        df -k /boot
        ls -l /boot/EFI/nixos /boot/loader/entries
        touch /var/lib/bench-first-boot
        echo FIRST-BOOT-DONE
        systemctl --no-block poweroff
      '';
    };
  });
in import (nixpkgs + "/nixos/lib/make-disk-image.nix") {
  inherit pkgs;
  inherit (pkgs) lib;
  inherit (base) config;
  format = "raw";
  partitionTableType = "efi";
  installBootLoader = true;
  bootSize = "248M";
  diskSize = "auto";
  additionalSpace = "512M";
}
NIX
    run_logged nix-build docker run --rm --network host --device /dev/kvm -v system-rescuer-nix:/nix -v "$work:/work" -w /work \
        -e NIX_CONFIG=$'extra-system-features = kvm\nsandbox = false' \
        nixos/nix sh -c 'nix-build image.nix -o /tmp/result && cp -L /tmp/result/nixos.img /work/nixos.img'
    mv -f -- "$work/nixos.img" "$img"
}
