#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A scratch Debian VM in which someone with no knowledge of the project
# follows docs/quickstart.md, and the check that the stick they wrote boots to
# a running agent.
#
#   tests/quickstart-vm.sh up <name> <export-dir> [--port <n>] [--mem <MiB>] [--user <u>] [--hostname <h>]
#   tests/quickstart-vm.sh check <name> [--record]
#   tests/quickstart-vm.sh down <name>
#
# up boots the Debian 13 nocloud image (a qcow2 overlay) under qemu with KVM
# and user-mode networking, the only host exposure an SSH forward on
# 127.0.0.1:<port> (default 2301), and leaves it running. The VM has:
# - a user (`walker` unless --user names another) with passwordless sudo,
#   reached with ssh -p <port> -i <dir>/vm-key <user>@127.0.0.1 (<dir>/access
#   says so), on a VM named `localhost` unless --hostname names it;
# - an 80 GiB scratch disk holding /home, /var/tmp and /var/lib/docker (the
#   root disk is too small to build on);
# - a 4000 MiB removable USB stick (<dir>/vm/stick.img), plugged in;
# - <export-dir> (tests/public-export.sh's tree) as a one-commit repository
#   at /srv/system-rescuer.git, the URL the walker clones;
# - ~walker/api-key, a scratch key, and ~walker/provider-ca.pem, the CA of the
#   stand-in provider tests/bench/provider-stub.py serves on the host as
#   https://10.0.2.2:8443/v1 during check. No real key enters the VM.
# Nothing else is installed: not git, minisign, Docker nor archiso, so the
# walk shows whether the quickstart names them.
#
# check copies the stick image and boots it with tests/qemu-boot.sh in
# provider-stub mode, logging in with the walker's ~/.ssh/id_ed25519 (copied
# out of the VM); --record also requires the key to come from a key record
# (a stick written by install.sh --prebuilt). down stops the VM and removes
# its disks.
#
# Everything lives in ~/.cache/system-rescuer/quickstart-vm/<name>/; the
# stand-in provider's configuration is shared in .../quickstart-vm/stub/.
# Needs what tests/install-vm.sh needs, and git.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/install-vm/debian-vm.sh
. "$here/tests/install-vm/debian-vm.sh"
top=$HOME/.cache/system-rescuer/quickstart-vm
stub_port=8443

die() { printf 'quickstart-vm: %s\n' "$*" >&2; exit 1; }
usage() { die "usage: tests/quickstart-vm.sh up <name> <export-dir> [--port <n>] [--mem <MiB>] [--user <u>] [--hostname <h>] | check <name> [--record] | down <name>"; }

cmd=${1:-} name=${2:-}
[[ -n $cmd && $name =~ ^[a-z0-9-]+$ && $name != stub ]] || usage
shift 2
dir=$top/$name vm=$top/$name/vm stub=$top/stub

vm_ssh() {
    local who=$1 port; shift
    port=$(sed -n 's/^port=//p' "$dir/access")
    ssh -p "$port" -i "$dir/vm-key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "$who@127.0.0.1" "$@"
}

# Stops qemu and waits for it to go, so its port is free for the next up.
vm_stop() {
    local pid n=0
    [[ -r $vm/qemu.pid ]] || return 0
    pid=$(cat "$vm/qemu.pid")
    kill "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && (( n++ < 60 )); do sleep 0.5; done
    rm -f -- "$vm/qemu.pid"
}

case $cmd in
up)
    src=${1:-}; [[ -n $src ]] || usage; shift
    port=2301 mem=8192 user=walker host=''
    while (( $# )); do
        case $1 in
            --port) port=${2:?}; shift ;;
            --mem) mem=${2:?}; shift ;;
            --user) user=${2:?}; shift ;;
            --hostname) host=${2:?}; shift ;;
            *) usage ;;
        esac
        shift
    done
    [[ -f $src/docs/quickstart.md ]] || die "$src is not an exported tree (no docs/quickstart.md)"
    [[ ! -e $src/AGENTS.md && ! -e $src/ROADMAP.md ]] || die "$src carries the development process; export it with tests/public-export.sh"
    [[ -r $base_image ]] || die "missing $base_image"
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable"
    [[ ! -r $vm/qemu.pid ]] || die "$name is already up; tests/quickstart-vm.sh down $name first"
    [[ $user =~ ^[a-z][a-z0-9-]*$ && ( -z $host || $host =~ ^[a-z][a-z0-9-]*$ ) ]] || die "--user and --hostname take a plain lower-case name"

    # The stand-in provider, shared by every walk.
    install -d -m 700 "$top" "$stub"
    [[ -f $stub/ca.pem ]] || python3 -I "$here/tests/bench/provider-stub.py" --ca-only --ca-dir "$stub" > /dev/null
    [[ -s $stub/api-key ]] || ( umask 077; printf 'sk-%s' "$(openssl rand -hex 24)" > "$stub/api-key" )
    printf 'key_file=api-key\nprovider_url=https://10.0.2.2:%s/v1\nprovider_ca_file=ca.pem\n' "$stub_port" > "$stub/rescue.conf"

    rm -rf -- "$dir"
    install -d -m 700 "$dir" "$vm"
    ssh-keygen -q -t ed25519 -N '' -C "quickstart-vm-$name" -f "$dir/vm-key"
    printf 'port=%s\nuser=%s\n' "$port" "$user" > "$dir/access"

    # The repository: the exported tree as one commit.
    git init -q -b main "$dir/repo"
    cp -a -- "$src/." "$dir/repo/"
    git -C "$dir/repo" add -A
    git -C "$dir/repo" -c user.name=system-rescuer -c user.email=walk commit -q -m "system-rescuer"
    git clone -q --bare "$dir/repo" "$dir/system-rescuer.git"

    qemu-img create -q -f qcow2 "$vm/big.qcow2" 80G
    truncate -s $(( 4000 * 1048576 )) "$vm/stick.img"
    debian_vm_boot "$vm" "$port" "$mem" \
        -drive file="$vm/big.qcow2",if=none,id=big,format=qcow2 \
        -device virtio-blk-pci,drive=big,serial=bigdisk \
        -device qemu-xhci,id=xhci \
        -drive file="$vm/stick.img",if=none,id=stick,format=raw \
        -device usb-storage,bus=xhci.0,drive=stick,removable=on || die "qemu did not start"

    pubkey=$(cat "$dir/vm-key.pub")
    debian_vm_provision "$vm" "$user" "$pubkey" "$host" <<EOF || die "the console provisioning failed; see $vm/console.log"
mkfs.ext4 -q -F /dev/disk/by-id/virtio-bigdisk
mkdir -p /big
mount /dev/disk/by-id/virtio-bigdisk /big
mkdir -p /big/home /big/vartmp /big/docker /var/lib/docker
chmod 1777 /big/vartmp
mount --bind /big/home /home
mount --bind /big/vartmp /var/tmp
mount --bind /big/docker /var/lib/docker
EOF
    debian_vm_wait_ssh vm_ssh "$user" true || die "no SSH login to the VM; see $vm/console.log"
    tar -C "$dir" -cf - system-rescuer.git | vm_ssh root 'tar -C /srv -xf - && chmod -R a+rX /srv/system-rescuer.git'
    vm_ssh "$user" 'umask 077; cat > api-key' < "$stub/api-key"
    vm_ssh "$user" 'cat > provider-ca.pem' < "$stub/ca.pem"
    printf 'quickstart-vm: %s is up: ssh -p %s -i %s %s@127.0.0.1\n' "$name" "$port" "$dir/vm-key" "$user"
    ;;
check)
    record=0
    [[ ${1:-} != --record ]] || { record=1; shift; }
    (( $# == 0 )) || usage
    [[ -r $vm/stick.img ]] || die "$name has no stick image"
    # Every walker's image names the stand-in at the same port, so one check
    # runs at a time.
    exec 9> "$top/check.lock"
    flock 9
    vm_ssh root sync
    user=$(sed -n 's/^user=//p' "$dir/access"); user=${user:-walker}
    ( umask 077; vm_ssh root "cat /home/$user/.ssh/id_ed25519" > "$dir/walker-key" ) \
        || die "the walker has no ~/.ssh/id_ed25519 to log in to the stick with"
    copy=$dir/stick-copy.img
    cp --sparse=always -- "$vm/stick.img" "$copy"
    expect=()
    (( ! record )) || expect=(RESCUE_EXPECT_RECORD=1)
    rc=0
    env "${expect[@]}" RESCUE_CONFIG="$stub" RESCUE_SSH_KEY="$dir/walker-key" RESCUE_PROVIDER_STUB="$stub" \
        "$here/tests/qemu-boot.sh" "$copy" || rc=$?
    rm -f -- "$copy"
    (( rc == 0 )) || die "the walker's stick did not boot to a running agent (qemu-boot.sh exit $rc)"
    printf 'PASS: the stick written by the %s walk boots to a running agent\n' "$name"
    ;;
down)
    (( $# == 0 )) || usage
    vm_stop
    rm -rf -- "$vm" "$dir/repo"
    ;;
*) usage ;;
esac
