#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Prove install.sh in a scratch Debian VM: a host that has no mkarchiso and, at
# first, no container runtime.
#
#   tests/install-vm.sh [--keep] [--port <n>] [--mem <MiB>] [--iso <file>] [--nokey-iso <file>] [--bare-iso <file>]
#
# 1. Boots the Debian 13 nocloud cloud image (a qcow2 overlay, so the
#    downloaded file is never modified) under qemu with KVM and user-mode
#    networking; the only host exposure is an SSH forward on 127.0.0.1:<port>
#    (default 2290). A second scratch disk is /big, with /var/lib/docker on it and the ISO built there
#    (the root disk is too small).
# 2. Drives the serial console once (tests/install-vm/console.py) to set up a
#    root password, sshd and an unprivileged user, then works over SSH.
# 3. Copies in the working tree and a stub configuration (a scratch API key, a
#    scratch SSH key, the provider stub's CA; no real key ever enters the VM).
# 4. Shows `install.sh --build-only` stopping at the host check, with a message
#    naming the missing container runtime.
# 5. Installs Docker from Debian's repository and runs `install.sh --build-only`,
#    which builds the ISO in a privileged archlinux container.
# 6. Copies the ISO out, checks its sha256, and boots it on the host with
#    RESCUE_PROVIDER_STUB=<stub config> tests/qemu-boot.sh.
# 7. The stick stage: qemu attaches image-file disks (a removable USB stick, a
#    non-removable USB disk, a SATA disk, a virtio disk) and install.sh is
#    driven over `ssh -tt`, the typed-back name on stdin. It must refuse every
#    disk but the stick, and the stick while a partition is mounted outside
#    /run/media, while swap is on it, while a dm-linear device sits on it and
#    on a wrong typed-back name; --dry-run leaves the stick image unchanged;
#    the build and write (or --iso) verifies the stick, which then boots with
#    the provider stub; a second write clears a key record left past the
#    image; --clean leaves no copy of the scratch key; --wipe zeroes the stick.
#
# 8. The prebuilt stage: a key-less image is built (install.sh --build-only
#    --no-key, from a configuration whose authorized_keys holds only a decoy,
#    so only --ssh-key can let SSH in; a second key-less image, with the stub's
#    authorized_keys, is the bare stick that must reach tty1's key prompt), signed with a scratch minisign key, and written with
#    `install.sh --prebuilt`, from a local file (--image) and from a local
#    HTTP server in the VM (--base-url). Each stick image boots with the
#    provider stub to a running agent on the key from its record, nothing
#    typed, with SSH by the scratch key; its image region has the image's
#    sha256. A changed byte, a wrong signature, a wrong .sha256, a missing
#    .minisig and a test-signed image without --trust-key (the pinned release
#    key) are each refused with the stick unchanged; a
#    key-less stick with no record still boots to tty1's key prompt; no file
#    of the VM has the scratch API key outside the stub configuration; --wipe
#    zeroes the stick.
#    The key-less images are built with --repo-asset (the repository as its own
#    file, each file under 1.9 GiB), both signed; `--prebuilt --image <img> --repo
#    <asset>` writes the asset past the key record, with a header, and the stick
#    boots with the repository found past the image. An asset with a changed
#    byte, signed by another key, with a wrong .sha256, with no .minisig, of
#    another image, or with its image UUID changed and re-signed is refused with
#    the stick unchanged. A stick whose asset is damaged, or whose header names
#    another image, boots online only and says why; rewritten with another image
#    the stick has no header left and boots online only.
#    Every asset is signed with the trusted comment file:<name><TAB>version:v0.0.1;
#    a comment naming the other asset, minisign's default comment, a version
#    other than the one asked for, an image and an asset of different versions,
#    and a --prebuilt version not of the form vN.N.N are refused with the stick
#    unchanged, and the verified version is printed.
#
# --iso <file> reuses a built ISO (with its .sha256): steps 1 to 6 are skipped
# and the stick stage writes that ISO with `install.sh --iso`, so the refusal
# cases need no rebuild. Only a full run proves the build-and-write and the
# Docker volumes' cleaning. --nokey-iso <file> likewise reuses a key-less image
# (with its .sha256) in the prebuilt stage, and --bare-iso the one with the
# stub's authorized_keys; each needs its repository asset beside it (the image's
# name with -repo.img for .iso, and its .sha256). A full run leaves its own in
# ~/.cache/system-rescuer/install-vm/out/nokey/ for that.
# The key-less image must be one the harness built (the stub's CA inside):
# the proxy trusts only the CA built into the image, so a release image
# (release/build-image.sh, the example configuration) is verified and written
# here but cannot reach the stub, and its boot is proved on the real provider
# by tests/scenario.sh --key-record instead.
#
# Needs: qemu-system-x86_64 with KVM, edk2-ovmf, ssh, openssl, python3, and the
# image ~/.cache/system-rescuer/downloads/debian-13-nocloud-amd64.qcow2. It
# takes up to an hour (the build downloads the Arch packages). Everything
# lives in ~/.cache/system-rescuer/install-vm/; the VM and its overlay go away
# at the end unless --keep. Run it in the background with its output in a log.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/install-vm/debian-vm.sh
. "$here/tests/install-vm/debian-vm.sh"
work=$HOME/.cache/system-rescuer/install-vm
port=2290 mem=8192 keep=0 iso_arg='' nokey_arg='' bare_arg=''
stub_port=8443

die() { printf 'install-vm: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

while (( $# )); do
    case $1 in
        --keep) keep=1 ;;
        --port) port=${2:?}; shift ;;
        --mem) mem=${2:?}; shift ;;
        --iso) iso_arg=$(realpath -- "${2:?}"); shift ;;
        --nokey-iso) nokey_arg=$(realpath -- "${2:?}"); shift ;;
        --bare-iso) bare_arg=$(realpath -- "${2:?}"); shift ;;
        *) die "usage: tests/install-vm.sh [--keep] [--port <n>] [--mem <MiB>] [--iso <file>] [--nokey-iso <file>] [--bare-iso <file>]" ;;
    esac
    shift
done
[[ -r $base_image ]] || die "missing $base_image"
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not usable"
[[ -r $ovmf_code && -r $ovmf_vars ]] || die "edk2-ovmf is not installed"
[[ -z $iso_arg ]] || [[ -r $iso_arg && -r $iso_arg.sha256 ]] || die "--iso needs the ISO and its .sha256 beside it"
[[ -z $nokey_arg ]] || [[ -r $nokey_arg && -r $nokey_arg.sha256 ]] || die "--nokey-iso needs the image and its .sha256 beside it"
[[ -z $bare_arg ]] || [[ -r $bare_arg && -r $bare_arg.sha256 ]] || die "--bare-iso needs the image and its .sha256 beside it"
for f in "$nokey_arg" "$bare_arg"; do
    [[ -z $f ]] || [[ -r ${f%.iso}-repo.img && -r ${f%.iso}-repo.img.sha256 ]] \
        || die "$f needs its repository asset ${f%.iso}-repo.img and its .sha256 beside it (build with install.sh --build-only --no-key --repo-asset)"
done

install -d -m 700 "$work"
vm=$work/vm
rm -rf -- "$vm"
install -d -m 700 "$vm" "$work/out"
stub_cfg=$work/stub-config

qemu_pid=''
cleanup() {
    [[ -z $qemu_pid ]] || kill "$qemu_pid" 2>/dev/null || true
    if (( ! keep )); then rm -rf -- "$vm"; fi
}
trap cleanup EXIT

# The stub configuration: everything the image is built from, scratch values.
step "stub configuration in $stub_cfg"
install -d -m 700 "$stub_cfg"
python3 -I "$here/tests/bench/provider-stub.py" --ca-only --ca-dir "$stub_cfg" > /dev/null
[[ -f $stub_cfg/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C install-vm-stub -f "$stub_cfg/id_ed25519"
cp -- "$stub_cfg/id_ed25519.pub" "$stub_cfg/authorized_keys"
[[ -s $stub_cfg/api-key ]] || ( umask 077; printf 'sk-%s' "$(openssl rand -hex 24)" > "$stub_cfg/api-key" )
cat > "$stub_cfg/rescue.conf" <<EOF
key_file=api-key
ssh_identity=id_ed25519
provider_url=https://10.0.2.2:$stub_port/v1
provider_ca_file=ca.pem
provider_key_prefix=sk-
EOF
# The VM's login key, apart from the stub's.
[[ -f $work/vm-key ]] || ssh-keygen -q -t ed25519 -N '' -C install-vm -f "$work/vm-key"

# The VM: an overlay on the downloaded image, and a scratch disk for Docker.
step "booting the Debian VM (KVM, user-mode networking, ssh on 127.0.0.1:$port)"
qemu-img create -q -f qcow2 "$vm/docker.qcow2" 60G
# The disks of the stick stage, sparse image files told apart by size: a USB
# stick, a USB disk that says it is not removable, a SATA disk and a virtio
# disk (which has no transport).
mib=1048576
size_stick=$(( 4000 * mib )) size_nrm=$(( 4100 * mib )) size_sata=$(( 4200 * mib )) size_vio=$(( 4300 * mib ))
truncate -s "$size_stick" "$vm/stick.img"
truncate -s "$size_nrm" "$vm/usb-fixed.img"
truncate -s "$size_sata" "$vm/sata.img"
truncate -s "$size_vio" "$vm/virtio.img"
debian_vm_boot "$vm" "$port" "$mem" \
    -drive file="$vm/docker.qcow2",if=none,id=docker,format=qcow2 \
    -device virtio-blk-pci,drive=docker,serial=dockerdisk \
    -device qemu-xhci,id=xhci \
    -drive file="$vm/stick.img",if=none,id=stick,format=raw \
    -device usb-storage,bus=xhci.0,drive=stick,removable=on \
    -drive file="$vm/usb-fixed.img",if=none,id=usbfixed,format=raw \
    -device usb-storage,bus=xhci.0,drive=usbfixed,removable=off \
    -device ich9-ahci,id=ahci \
    -drive file="$vm/sata.img",if=none,id=sata,format=raw \
    -device ide-hd,bus=ahci.0,drive=sata \
    -drive file="$vm/virtio.img",if=none,id=vio,format=raw \
    -device virtio-blk-pci,drive=vio || die "qemu did not start"
qemu_pid=$(cat "$vm/qemu.pid")

# Serial console, once: a scratch file system for Docker, sshd, a user.
pubkey=$(cat "$work/vm-key.pub")
debian_vm_provision "$vm" builder "$pubkey" '' dmsetup fdisk e2fsprogs <<EOF || die "the console provisioning failed; see $vm/console.log"
mkfs.ext4 -q -F /dev/disk/by-id/virtio-dockerdisk
mkdir -p /big
mount /dev/disk/by-id/virtio-dockerdisk /big
mkdir -p /big/docker /var/lib/docker
mount --bind /big/docker /var/lib/docker
EOF

ssh_opts=(-p "$port" -i "$work/vm-key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
# shellcheck disable=SC2029  # the command is meant to expand here
vm_ssh() { local who=$1; shift; ssh "${ssh_opts[@]}" "$who@127.0.0.1" "$@"; }
# With a terminal, for the prompts that read /dev/tty: stdin is the answers.
vm_tty() { local who=$1; shift; ssh -tt "${ssh_opts[@]}" "$who@127.0.0.1" "$@"; }
debian_vm_wait_ssh vm_ssh builder true || die "no SSH login to the VM; see $vm/console.log"
printf 'ssh login as builder: ok\n'

step "copying the working tree and the stub configuration"
tar -C "$here" --exclude=./.git --exclude=./out -cf - . \
    | vm_ssh builder 'rm -rf system-rescuer && mkdir system-rescuer && tar -C system-rescuer -xf -'
tar -C "$stub_cfg" -cf - . | vm_ssh builder 'rm -rf config && mkdir config && tar -C config -xf -'
vm_ssh builder 'chmod 700 config && chmod 600 config/api-key config/id_ed25519'

if [[ -z $iso_arg ]]; then
    step "1. install.sh --build-only with no container runtime"
    rc=0
    vm_ssh builder 'cd system-rescuer && ./install.sh --build-only --config ~/config --out-dir /big/iso-out' > "$vm/refused.log" 2>&1 || rc=$?
    cat "$vm/refused.log"
    (( rc != 0 )) || die "install.sh did not refuse a host without a container runtime"
    grep -q 'no container runtime' "$vm/refused.log" || die "the refusal does not name the missing container runtime"
    vm_ssh builder 'test ! -e /big/iso-out/build.log' || die "something was built before the host check refused"
    printf 'PASS: refused at the host check (exit %s), naming the missing runtime\n' "$rc"

    step "2. Docker from Debian's repository, then install.sh --build-only"
    vm_ssh root 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io && usermod -aG docker builder && install -d -o builder -g builder /big/iso-out && systemctl enable --now docker' \
        > "$vm/docker-install.log" 2>&1 || { tail -n 20 "$vm/docker-install.log"; die "could not install Docker"; }
    vm_ssh builder 'cd system-rescuer && ./install.sh --build-only --config ~/config --out-dir /big/iso-out' 2>&1 | tee "$vm/build.log"
    vm_ssh builder 'ls -l /big/iso-out' || true

    step "copying the ISO out and checking it"
    iso_name=$(vm_ssh builder 'cd /big/iso-out && ls system-rescuer-*.iso' | sort | tail -n 1)
    [[ -n $iso_name ]] || die "no ISO in the VM's out/"
    rm -f -- "$work/out/$iso_name" "$work/out/$iso_name.sha256"
    for f in "$iso_name" "$iso_name.sha256" "$iso_name.model"; do
        vm_ssh builder "cat /big/iso-out/$f" > "$work/out/$f"
    done
    ( cd "$work/out" && sha256sum -c "$iso_name.sha256" ) || die "the copied ISO does not match its sha256"
    printf 'PASS: %s sha256 %s\n' "$work/out/$iso_name" "$(cut -d' ' -f1 "$work/out/$iso_name.sha256")"

    step "tests/qemu-boot.sh in provider-stub mode"
    RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$work/out/$iso_name"
    printf '\nPASS: install.sh built an ISO in the Debian VM that passes qemu-boot.sh in stub mode\n'
else
    iso_name=$(basename "$iso_arg")
    vm_ssh root 'install -d -o builder -g builder /big/iso-out'
    for f in "$iso_name" "$iso_name.sha256"; do
        vm_ssh builder "cat > /big/iso-out/$f" < "$(dirname "$iso_arg")/$f"
    done
    printf 'reusing %s\n' "$iso_arg"
fi

step "7. stick stage: the disks the VM sees"
vm_ssh root 'lsblk -dbno NAME,SIZE,TRAN,RM,MODEL' || true
disk_by_size() { vm_ssh root 'lsblk -dbno NAME,SIZE' | awk -v s="$1" '$2 == s {print $1}'; }
d_stick=$(disk_by_size "$size_stick"); d_nrm=$(disk_by_size "$size_nrm")
d_sata=$(disk_by_size "$size_sata"); d_vio=$(disk_by_size "$size_vio")
[[ -n $d_stick && -n $d_nrm && -n $d_sata && -n $d_vio ]] || die "the VM does not show all four stage disks"
printf 'stick /dev/%s, non-removable usb /dev/%s, sata /dev/%s, virtio /dev/%s\n' "$d_stick" "$d_nrm" "$d_sata" "$d_vio"
vm_iso=/big/iso-out/$iso_name
vm_cfg=/home/builder/config
# Scratch space for install.sh (TMPDIR): the root disk is too small for an image.
vm_ssh root 'install -d -m 700 -o builder -g builder /big/tmp'

# run_install <stdin text> <install.sh args...>: install.sh over a terminal in
# the VM; its output is in $vm/last.txt and its status is returned.
run_install() {
    local input=$1 rc=0; shift
    { printf '%b' "$input"; sleep 5; } | vm_tty builder "cd system-rescuer && TMPDIR=/big/tmp ./install.sh $*" > "$vm/last.log" 2>&1 || rc=$?
    tr -d '\r' < "$vm/last.log" > "$vm/last.txt"
    cat "$vm/last.txt"
    return "$rc"
}
# expect_refused <label> <pattern> <stdin text> <install.sh args...>
expect_refused() {
    local label=$1 pat=$2 input=$3 rc=0; shift 3
    run_install "$input" "$@" > /dev/null || rc=$?
    (( rc != 0 )) || { cat "$vm/last.txt"; die "$label: install.sh did not refuse"; }
    grep -q -- "$pat" "$vm/last.txt" || { cat "$vm/last.txt"; die "$label: refused for another reason"; }
    printf 'PASS: %s refused (%s)\n' "$label" "$(grep -m1 -- "$pat" "$vm/last.txt")"
}
img_sha() { sha256sum "$vm/stick.img" | cut -d' ' -f1; }
img_zero() { cmp -s -n "$(stat -c %s "$1")" "$1" /dev/zero; }

expect_refused "the SATA disk" "transport is 'sata', not usb" '' --iso "$vm_iso" "/dev/$d_sata"
expect_refused "the non-removable USB disk" "it is not removable" '' --iso "$vm_iso" "/dev/$d_nrm"
expect_refused "the virtio disk (qemu reports transport virtio, not an empty one)" "its transport is" '' --iso "$vm_iso" "/dev/$d_vio"
for f in sata.img usb-fixed.img virtio.img; do
    img_zero "$vm/$f" || die "$f was written to"
done
printf 'PASS: the three refused disks are still all zero\n'

# A partition table with one file system on the stick, for the holder cases.
vm_ssh root "printf 'label: dos\n,100MiB\n' | sfdisk -q /dev/$d_stick && udevadm settle && mkfs.ext4 -q /dev/${d_stick}1"
expect_refused "a partition ($d_stick""1)" "not a whole disk" '' --iso "$vm_iso" "/dev/${d_stick}1"
vm_ssh root "install -d /mnt/stick && mount /dev/${d_stick}1 /mnt/stick"
expect_refused "the stick with a partition mounted at /mnt/stick" "mounted at /mnt/stick" '' --iso "$vm_iso" "/dev/$d_stick"
vm_ssh root 'umount /mnt/stick'
vm_ssh root "mkswap -q /dev/${d_stick}1 && swapon /dev/${d_stick}1"
expect_refused "the stick with active swap" "swap is active" '' --iso "$vm_iso" "/dev/$d_stick"
vm_ssh root "swapoff /dev/${d_stick}1"
vm_ssh root "dmsetup create stickmap --table '0 2048 linear /dev/${d_stick}1 0'"
expect_refused "the stick with a dm-linear device on it" "is built on it" '' --iso "$vm_iso" "/dev/$d_stick"
vm_ssh root 'dmsetup remove stickmap'

# A desktop auto-mount is unmounted when asked and agreed.
vm_ssh root "mkfs.ext4 -q /dev/${d_stick}1 && install -d /run/media/builder/STICK && mount /dev/${d_stick}1 /run/media/builder/STICK"
run_install 'y\n' --dry-run --iso "$vm_iso" "/dev/$d_stick" > /dev/null
grep -q 'Dry run: every check passed' "$vm/last.txt" || die "the auto-mounted stick was not accepted after unmounting"
vm_ssh root '! mountpoint -q /run/media/builder/STICK' || die "the auto-mount is still mounted"
printf 'PASS: a /run/media auto-mount was unmounted on request and the dry run passed\n'

sum0=$(img_sha)
expect_refused "the stick with a wrong typed-back name" "is not '$d_stick'; nothing was written" 'sdzz\n' --iso "$vm_iso" "/dev/$d_stick"
[[ $(img_sha) == "$sum0" ]] || die "the stick changed after the refused write"
run_install '' --dry-run --iso "$vm_iso" "/dev/$d_stick" > /dev/null
grep -q 'Stopping before the first byte' "$vm/last.txt" || die "the dry run did not stop"
run_install "/dev/$d_stick\n" --dry-run --iso "$vm_iso" > /dev/null
grep -q 'Candidate sticks' "$vm/last.txt" || die "no candidate list"
grep -q "/dev/$d_stick " "$vm/last.txt" || die "the stick is not a candidate"
if grep -E "^ +/dev/($d_sata|$d_nrm|$d_vio) " "$vm/last.txt"; then die "a refused disk is a candidate"; fi
[[ $(img_sha) == "$sum0" ]] || die "the stick changed after --dry-run"
printf 'PASS: --dry-run (named and chosen from the candidates) left the stick image at sha256 %s\n' "$sum0"

step "the write"
if [[ -z $iso_arg ]]; then
    run_install "$d_stick\n" --config "$vm_cfg" --out-dir /big/iso-out "/dev/$d_stick"
else
    run_install "$d_stick\n" --iso "$vm_iso" "/dev/$d_stick"
fi
grep -q "Wrote and verified /dev/$d_stick" "$vm/last.txt" || die "install.sh did not report a verified write"
cur_sum=$(vm_ssh builder "cut -d' ' -f1 /big/iso-out/$iso_name.sha256")
cur_size=$(vm_ssh builder "stat -c %s /big/iso-out/$iso_name")
vm_ssh root sync
stick_sum=$(head -c "$cur_size" "$vm/stick.img" | sha256sum | cut -d' ' -f1)
[[ $stick_sum == "$cur_sum" ]] || die "the stick image's first $cur_size bytes are sha256 $stick_sum, not the ISO's $cur_sum"
printf 'PASS: the stick image starts with the ISO: sha256 %s (%s bytes)\n' "$stick_sum" "$cur_size"
stick_copy=$work/out/stick-$iso_name.img
cp --sparse=always -- "$vm/stick.img" "$stick_copy"
printf 'PASS: install.sh verified the write (%s)\n' "$(grep -m1 'Wrote and verified' "$vm/last.txt")"

step "tests/qemu-boot.sh on the written stick image, stub mode"
RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$stick_copy"
rm -f -- "$stick_copy"
printf 'PASS: the written stick image boots to a running agent\n'

step "a second write clears a key record left past the image"
rec_off=$(( (cur_size + mib - 1) / mib * mib ))
python3 -I - "$vm/stick.img" "$rec_off" <<'PY'
import sys
path, off = sys.argv[1], int(sys.argv[2])
with open(path, "r+b") as f:
    f.seek(off)
    f.write(b"RSCKEY01" + b"%08d" % 51 + b"k" * 51)
PY
run_install "$d_stick\n" --iso "$vm_iso" "/dev/$d_stick"
grep -q "Wrote and verified /dev/$d_stick" "$vm/last.txt" || die "the second write did not verify"
python3 -I - "$vm/stick.img" "$rec_off" <<'PY' || die "the old record is still on the stick"
import sys
path, off = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as f:
    f.seek(off)
    data = f.read(1048576)
sys.exit(1 if any(data) else 0)
PY
printf 'PASS: the record at byte %s is gone after the second write, which verified\n' "$rec_off"

step "--clean"
key_sha=$(sha256sum "$stub_cfg/api-key" | cut -d' ' -f1)
key_copies() {
    vm_ssh root "find / /big /tmp /run -xdev -type f -size +40c -size -60c -not -path '/home/builder/config/*' -not -path '/proc/*' -exec sha256sum {} + 2> /dev/null | grep -c '$key_sha' || true"
}
vm_ssh builder 'umask 077 && mkdir -p /tmp/rescue-install.leftover && cp ~/config/api-key /tmp/rescue-install.leftover/key'
before=$(key_copies)
(( before >= 1 )) || die "the search finds no copy of the scratch key before --clean; it proves nothing"
printf 'copies of the scratch key before --clean: %s\n' "$before"
run_install 'y\n' --clean --out-dir /big/iso-out
after=$(key_copies)
(( after == 0 )) || die "$after copies of the scratch key remain after --clean"
leaks=$(vm_ssh root "grep -rlF -f /home/builder/config/api-key /var/tmp /tmp /run /big/docker/volumes /var/lib/docker/volumes 2> /dev/null | wc -l")
(( leaks == 0 )) || die "grep finds the key's bytes in $leaks files after --clean"
vm_ssh root '! ls /big/iso-out/system-rescuer-*.iso > /dev/null 2>&1' || die "an ISO is left after --clean"
printf 'PASS: after --clean no file has the scratch key'"'"'s sha256 (%s before) and grep -rlF finds no key bytes\n' "$before"

step "--wipe"
run_install "$d_stick\n" --wipe "/dev/$d_stick"
vm_ssh root sync
img_zero "$vm/stick.img" || die "the stick image has a non-zero byte after --wipe"
printf 'PASS: after --wipe the stick image has no non-zero byte\n'
printf '\nPASS: the stick stage\n'

step "8. prebuilt stage: the key-less image, signed with a scratch key"
vm_ssh root 'install -d -m 700 -o builder -g builder /big/tmp /big/pb /big/pb-bad /big/nokey-out'
vm_ssh root 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq minisign python3' > "$vm/minisign-install.log" 2>&1 \
    || { tail -n 20 "$vm/minisign-install.log"; die "could not install minisign in the VM"; }
# shellcheck source=lib/release-layout.sh
. "$here/lib/release-layout.sh"
pb_name=$release_iso repo_name=$release_repo
gib19=$(( 1900 * mib ))
ensure_docker() {
    if ! vm_ssh root 'command -v docker' > /dev/null 2>&1; then
        vm_ssh root 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io && usermod -aG docker builder && systemctl enable --now docker' \
            > "$vm/docker-install.log" 2>&1 || { tail -n 20 "$vm/docker-install.log"; die "could not install Docker"; }
    fi
}
if [[ -n $nokey_arg ]]; then
    nokey_name=$(basename "$nokey_arg")
    vm_ssh builder "cat > /big/pb/$pb_name" < "$nokey_arg"
    vm_ssh builder "cat > /big/pb/$repo_name" < "${nokey_arg%.iso}-repo.img"
else
    ensure_docker
    # The stub configuration with only a decoy authorized_keys (a key nobody
    # holds; mkarchiso fails on a build with none, profiledef.sh names the file):
    # only --ssh-key can let the stub's key in.
    vm_ssh builder 'rm -rf config-nokeys decoy && cp -r config config-nokeys && ssh-keygen -q -t ed25519 -N "" -C decoy -f decoy && mv decoy.pub config-nokeys/authorized_keys && rm -f decoy'
    vm_ssh builder 'cd system-rescuer && ./install.sh --build-only --no-key --repo-asset --config ~/config-nokeys --out-dir /big/nokey-out' 2>&1 | tee "$vm/build-nokey.log"
    nokey_name=$(vm_ssh builder 'cd /big/nokey-out && ls system-rescuer-*.iso' | sort | tail -n 1)
    [[ -n $nokey_name ]] || die "no key-less ISO built"
    vm_ssh builder "test -e /big/nokey-out/$nokey_name.key-at-boot" || die "the key-less build left no key-at-boot marker"
    vm_ssh builder "test -e /big/nokey-out/$nokey_name.repo-asset && test -s /big/nokey-out/${nokey_name%.iso}-repo.img" || die "the --repo-asset build left no repository asset"
    vm_ssh builder "cp /big/nokey-out/$nokey_name /big/pb/$pb_name && cp /big/nokey-out/${nokey_name%.iso}-repo.img /big/pb/$repo_name"
    install -d -m 700 "$work/out/nokey"
    vm_ssh builder "cat /big/nokey-out/$nokey_name" > "$work/out/nokey/decoy-$nokey_name"
    vm_ssh builder "cat /big/nokey-out/$nokey_name.sha256" > "$work/out/nokey/decoy-$nokey_name.sha256"
    vm_ssh builder "cat /big/nokey-out/${nokey_name%.iso}-repo.img" > "$work/out/nokey/decoy-${nokey_name%.iso}-repo.img"
    vm_ssh builder "cat /big/nokey-out/${nokey_name%.iso}-repo.img.sha256" > "$work/out/nokey/decoy-${nokey_name%.iso}-repo.img.sha256"
fi
pb_sum=$(vm_ssh builder "sha256sum /big/pb/$pb_name" | cut -d' ' -f1)
pb_size=$(vm_ssh builder "stat -c %s /big/pb/$pb_name")
# The key-less ISO holds no byte string of the scratch key.
vm_ssh builder "! grep -qF -f ~/config/api-key /big/pb/$pb_name" || die "the key-less image holds the scratch key"
printf 'PASS: a key-less image of %s bytes, sha256 %s, with no byte string of the scratch key\n' "$pb_size" "$pb_sum"
pb_repo_sum=$(vm_ssh builder "sha256sum /big/pb/$repo_name" | cut -d' ' -f1)
pb_repo_size=$(vm_ssh builder "stat -c %s /big/pb/$repo_name")
(( pb_size < gib19 && pb_repo_size < gib19 )) || die "the image ($pb_size) or its repository asset ($pb_repo_size) is not under 1.9 GiB ($gib19)"
vm_ssh builder "! grep -qF -f ~/config/api-key /big/pb/$repo_name" || die "the repository asset holds the scratch key"
printf 'PASS: the image is %s bytes and the repository asset %s bytes, each under 1.9 GiB (%s); the asset names UUID %s\n' \
    "$pb_size" "$pb_repo_size" "$gib19" "$(vm_ssh builder "dd if=/big/pb/$repo_name bs=1 skip=$((32768 + 190)) count=128 status=none | tr -d '\\000 '")"

step "a second key-less image, for its own asset and for the bare stick"
# A second key-less image, built with the stub's authorized_keys (the decoy
# image accepts no login, and qemu-boot.sh needs SSH to see the prompt); its
# asset is another image's, for the refusals below.
if [[ -n $bare_arg ]]; then
    bare_name=$(basename "$bare_arg")
    vm_ssh root 'install -d -o builder -g builder /big/bare-out'
    for f in "$bare_name" "$bare_name.sha256" "${bare_name%.iso}-repo.img"; do vm_ssh builder "cat > /big/bare-out/$f" < "$(dirname "$bare_arg")/$f"; done
else
    ensure_docker
    install -d -m 700 "$work/out/nokey"
    vm_ssh root 'install -d -o builder -g builder /big/bare-out'
    vm_ssh builder 'cd system-rescuer && ./install.sh --build-only --no-key --repo-asset --config ~/config --out-dir /big/bare-out' 2>&1 | tee "$vm/build-bare.log"
    bare_name=$(vm_ssh builder 'cd /big/bare-out && ls system-rescuer-*.iso' | sort | tail -n 1)
    [[ -n $bare_name ]] || die "no bare key-less ISO built"
    vm_ssh builder "cat /big/bare-out/$bare_name" > "$work/out/nokey/bare-$bare_name"
    vm_ssh builder "cat /big/bare-out/$bare_name.sha256" > "$work/out/nokey/bare-$bare_name.sha256"
    vm_ssh builder "cat /big/bare-out/${bare_name%.iso}-repo.img" > "$work/out/nokey/bare-${bare_name%.iso}-repo.img"
    vm_ssh builder "cat /big/bare-out/${bare_name%.iso}-repo.img.sha256" > "$work/out/nokey/bare-${bare_name%.iso}-repo.img.sha256"
fi
# tcomment <asset name> <version>: a release asset's trusted comment, file and version split by a tab.
tcomment() { printf 'file:%s\tversion:%s' "$1" "$2"; }
sig_ver=v0.0.1
vm_ssh builder 'cd /big/pb-bad && rm -f key-a.* key-b.* && minisign -G -W -f -p key-a.pub -s key-a.sec > /dev/null && minisign -G -W -f -p key-b.pub -s key-b.sec > /dev/null'
vm_ssh builder "cd /big/pb && printf '%s  %s\n' $pb_sum $pb_name > $pb_name.sha256 && minisign -S -W -s /big/pb-bad/key-a.sec -t '$(tcomment "$pb_name" "$sig_ver")' -m $pb_name -x $pb_name.minisig > /dev/null"
vm_ssh builder "cd /big/pb && printf '%s  %s\n' $pb_repo_sum $repo_name > $repo_name.sha256 && minisign -S -W -s /big/pb-bad/key-a.sec -t '$(tcomment "$repo_name" "$sig_ver")' -m $repo_name -x $repo_name.minisig > /dev/null"
pub=/big/pb-bad/key-a.pub
vm_pb=/big/pb/$pb_name
vm_repo=/big/pb/$repo_name
pbargs=(--repo "$vm_repo" --key-file "$vm_cfg/api-key" --ssh-key "$vm_cfg/id_ed25519.pub" --endpoint "https://10.0.2.2:$stub_port/v1" --key-prefix sk-)

# The refusals leave the stick as it was.
sum0=$(img_sha)
expect_refused "a test-signed image against the pinned release key" "is not signed by the release key" '' --prebuilt --image "$vm_pb" "${pbargs[@]}" "/dev/$d_stick"
vm_ssh builder "cd /big/pb-bad && ln -f $vm_pb nosig.iso && cp /big/pb/$pb_name.sha256 nosig.iso.sha256"
expect_refused "an image with no .minisig" "no /big/pb-bad/nosig.iso.minisig beside the image" '' \
    --prebuilt --image /big/pb-bad/nosig.iso --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
# One byte changed (and its .sha256 recomputed, so only the signature can tell).
vm_ssh builder "cd /big/pb-bad && cp $vm_pb flip.iso && printf '\\245' | dd of=flip.iso bs=1 seek=$((pb_size / 2)) conv=notrunc status=none && sha256sum flip.iso | sed 's|  .*|  flip.iso|' > flip.iso.sha256 && cp /big/pb/$pb_name.minisig flip.iso.minisig"
expect_refused "an image with one byte changed" "signature check failed" '' \
    --prebuilt --image /big/pb-bad/flip.iso --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
# A signature made with another key.
vm_ssh builder "cd /big/pb-bad && cp $vm_pb other.iso && cp /big/pb/$pb_name.sha256 other.iso.sha256 && minisign -S -W -s key-b.sec -m other.iso -x other.iso.minisig > /dev/null"
expect_refused "an image signed with another key" "signature check failed" '' \
    --prebuilt --image /big/pb-bad/other.iso --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
# A wrong .sha256 (the signature is good).
vm_ssh builder "cd /big/pb-bad && cp $vm_pb wrongsum.iso && cp /big/pb/$pb_name.minisig wrongsum.iso.minisig && printf '%064d  wrongsum.iso\n' 7 > wrongsum.iso.sha256"
expect_refused "an image with a wrong .sha256" "sha256 mismatch" '' \
    --prebuilt --image /big/pb-bad/wrongsum.iso --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
# A key that is not a key, and an SSH key that is a private key.
expect_refused "--ssh-key naming a private key" "holds a private key" '' \
    --prebuilt --image "$vm_pb" --trust-key "$pub" --key-file $vm_cfg/api-key --ssh-key $vm_cfg/id_ed25519 "/dev/$d_stick"
# The repository asset's own refusals (the image itself is good).
rb=(--prebuilt --image "$vm_pb" --trust-key "$pub" --key-file "$vm_cfg/api-key")
# one byte of the asset changed (and its .sha256 recomputed, so only the signature can tell)
vm_ssh builder "cd /big/pb-bad && cp $vm_repo flip-repo.img && printf '\\245' | dd of=flip-repo.img bs=1 seek=$((pb_repo_size / 2)) conv=notrunc status=none && sha256sum flip-repo.img | sed 's|  .*|  flip-repo.img|' > flip-repo.img.sha256 && cp $vm_repo.minisig flip-repo.img.minisig"
expect_refused "an asset with one byte changed" "signature check failed: the repository asset" '' "${rb[@]}" --repo /big/pb-bad/flip-repo.img "/dev/$d_stick"
vm_ssh builder "cd /big/pb-bad && cp $vm_repo other-repo.img && cp $vm_repo.sha256 other-repo.img.sha256 && sed -i 's|$repo_name|other-repo.img|' other-repo.img.sha256 && minisign -S -W -s key-b.sec -m other-repo.img -x other-repo.img.minisig > /dev/null"
expect_refused "an asset signed with another key" "signature check failed: the repository asset" '' "${rb[@]}" --repo /big/pb-bad/other-repo.img "/dev/$d_stick"
vm_ssh builder "cd /big/pb-bad && cp $vm_repo wrong-repo.img && cp $vm_repo.minisig wrong-repo.img.minisig && printf '%064d  wrong-repo.img\n' 7 > wrong-repo.img.sha256"
expect_refused "an asset with a wrong .sha256" "sha256 mismatch" '' "${rb[@]}" --repo /big/pb-bad/wrong-repo.img "/dev/$d_stick"
vm_ssh builder "cd /big/pb-bad && cp $vm_repo nosig-repo.img && cp $vm_repo.sha256 nosig-repo.img.sha256"
expect_refused "an asset with no .minisig" "no /big/pb-bad/nosig-repo.img.minisig beside the repository asset" '' "${rb[@]}" --repo /big/pb-bad/nosig-repo.img "/dev/$d_stick"
# An asset of another image: a second image's own asset (the bare one, properly
# signed), and this image's asset with the UUID field changed and re-signed.
vm_ssh builder "cd /big/pb-bad && cp /big/bare-out/${bare_name%.iso}-repo.img bare-repo.img && sha256sum bare-repo.img | sed 's|  .*|  bare-repo.img|' > bare-repo.img.sha256 && minisign -S -W -s key-a.sec -t '$(tcomment "$repo_name" "$sig_ver")' -m bare-repo.img -x bare-repo.img.minisig > /dev/null"
expect_refused "the asset of another image (the bare one, signed by the same key)" "belongs to another image" '' "${rb[@]}" --repo /big/pb-bad/bare-repo.img "/dev/$d_stick"
vm_ssh builder "cd /big/pb-bad && cp $vm_repo uuid-repo.img && printf 'rescue-repo-for=%s' 2020-01-01_00-00-00-00 | tr _ - | dd of=uuid-repo.img bs=1 seek=$((32768 + 190)) conv=notrunc status=none && sha256sum uuid-repo.img | sed 's|  .*|  uuid-repo.img|' > uuid-repo.img.sha256 && minisign -S -W -s key-a.sec -t '$(tcomment "$repo_name" "$sig_ver")' -m uuid-repo.img -x uuid-repo.img.minisig > /dev/null"
expect_refused "an asset naming another UUID, re-signed" "belongs to another image" '' "${rb[@]}" --repo /big/pb-bad/uuid-repo.img "/dev/$d_stick"
# The trusted comment, signed by the right key, is the file name and version.
# image names the repository asset's file
vm_ssh builder "cd /big/pb-bad && ln -f $vm_pb swapimg.iso && cp /big/pb/$pb_name.sha256 swapimg.iso.sha256 && minisign -S -W -s key-a.sec -t '$(tcomment "$repo_name" "$sig_ver")' -m swapimg.iso -x swapimg.iso.minisig > /dev/null"
expect_refused "an image whose comment names the repository asset" "trusted comment mismatch: swapimg.iso is signed as 'file:$repo_name<TAB>version:$sig_ver', expected 'file:$pb_name" '' \
    --prebuilt --image /big/pb-bad/swapimg.iso --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
# a repository asset whose comment names the image's file
vm_ssh builder "cd /big/pb-bad && ln -f $vm_repo swaprepo.img && cp $vm_repo.sha256 swaprepo.img.sha256 && minisign -S -W -s key-a.sec -t '$(tcomment "$pb_name" "$sig_ver")' -m swaprepo.img -x swaprepo.img.minisig > /dev/null"
expect_refused "an asset whose comment names the image" "trusted comment mismatch: the repository asset swaprepo.img is signed as 'file:$pb_name<TAB>version:$sig_ver', expected 'file:$repo_name" '' \
    "${rb[@]}" --repo /big/pb-bad/swaprepo.img "/dev/$d_stick"
# minisign's default comment, a timestamp and the file name
vm_ssh builder "cd /big/pb-bad && ln -f $vm_pb dflt.iso && cp /big/pb/$pb_name.sha256 dflt.iso.sha256 && minisign -S -W -s key-a.sec -m dflt.iso -x dflt.iso.minisig > /dev/null"
expect_refused "an image with minisign's default comment" "trusted comment mismatch: dflt.iso is signed as" '' \
    --prebuilt --image /big/pb-bad/dflt.iso --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
# an image and an asset of different versions
vm_ssh builder "cd /big/pb-bad && ln -f $vm_repo v2-repo.img && cp $vm_repo.sha256 v2-repo.img.sha256 && minisign -S -W -s key-a.sec -t '$(tcomment "$repo_name" v0.0.2)' -m v2-repo.img -x v2-repo.img.minisig > /dev/null"
expect_refused "an image of v0.0.1 and an asset of v0.0.2" "version mismatch: the image is signed as version $sig_ver, the repository asset v2-repo.img as v0.0.2" '' \
    "${rb[@]}" --repo /big/pb-bad/v2-repo.img "/dev/$d_stick"
# a download of another version than the one asked for, from a local server
vm_ssh builder 'cd /big/pb && (nohup python3 -m http.server 8000 --bind 127.0.0.1 > /big/tmp/http.log 2>&1 < /dev/null & echo $! > /big/tmp/http.pid)'
sleep 2
expect_refused "a download signed as $sig_ver when v0.0.2 was asked for" "version mismatch: $pb_name is signed as version $sig_ver, but --prebuilt asked for v0.0.2" '' \
    --prebuilt v0.0.2 --base-url http://127.0.0.1:8000 --trust-key "$pub" "${pbargs[@]:2}" "/dev/$d_stick"
# shellcheck disable=SC2016  # expanded in the VM
vm_ssh builder 'kill $(cat /big/tmp/http.pid)' || true
expect_refused "--prebuilt v1.2" "must look like v1.2.3" '' --prebuilt v1.2 "/dev/$d_stick"
[[ $(img_sha) == "$sum0" ]] || die "the stick changed after a refused --prebuilt"
printf 'PASS: every refusal left the stick image at sha256 %s\n' "$sum0"

run_install '' --prebuilt --image "$vm_pb" --trust-key "$pub" "${pbargs[@]}" --dry-run "/dev/$d_stick" > /dev/null
grep -q 'Stopping before the first byte' "$vm/last.txt" || die "the --prebuilt dry run did not stop"
grep -q "signature: ok (minisign, .*; version $sig_ver)" "$vm/last.txt" || die "the --prebuilt dry run did not check the signature and name its version"
[[ $(img_sha) == "$sum0" ]] || die "the stick changed after the --prebuilt dry run"
printf 'PASS: --prebuilt --dry-run checked the signature and sha256 and left the stick unchanged\n'

# stick_peek <image-file> <offset> <bytes>: bytes of the image file.
stick_peek() { dd if="$1" bs=1 skip="$2" count="$3" status=none; }
# check_prebuilt_stick <label>: the written stick image, copied out, as booted:
# the image region, the key record, the repository header and asset read back
# from the file, then a boot with the repository found past the image.
check_prebuilt_stick() {
    local label=$1 copy=$work/out/stick-prebuilt.img got off hdr_len hdr
    vm_ssh root sync
    got=$(head -c "$pb_size" "$vm/stick.img" | sha256sum | cut -d' ' -f1)
    [[ $got == "$pb_sum" ]] || die "$label: the image region's sha256 is $got, not the image's $pb_sum"
    off=$(( (pb_size + mib - 1) / mib * mib ))
    [[ $(stick_peek "$vm/stick.img" "$off" 8) == RSCKEY02 ]] || die "$label: no record at byte $off"
    [[ $(stick_peek "$vm/stick.img" $(( off + mib )) 8) == RSCREPO1 ]] || die "$label: no repository header at byte $(( off + mib ))"
    hdr_len=$((10#$(stick_peek "$vm/stick.img" $(( off + mib + 8 )) 8)))
    hdr=$(stick_peek "$vm/stick.img" $(( off + mib + 16 )) "$hdr_len")
    [[ $hdr == *"size=$pb_repo_size"$'\n'* && $hdr == *"sha256=$pb_repo_sum"* && $hdr == *"uuid="* ]] || die "$label: the repository header is wrong: $hdr"
    got=$(dd if="$vm/stick.img" bs=1M skip=$(( off / mib + 2 )) iflag=count_bytes count="$pb_repo_size" status=none | sha256sum | cut -d' ' -f1)
    [[ $got == "$pb_repo_sum" ]] || die "$label: the asset on the stick is sha256 $got, not $pb_repo_sum"
    printf 'PASS: %s: the image region has the image'"'"'s sha256, RSCKEY02 is at byte %s, the repository header at %s and the asset (%s bytes, sha256 %s) at %s\n' \
        "$label" "$off" "$(( off + mib ))" "$pb_repo_size" "$got" "$(( off + 2 * mib ))"
    cp --sparse=always -- "$vm/stick.img" "$copy"
    RESCUE_EXPECT_RECORD=1 RESCUE_EXPECT_REPO=past RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$copy"
    rm -f -- "$copy"
    printf 'PASS: %s: the stick boots to a running agent on the recorded key, nothing typed, SSH with the scratch key, and the offline repository is found past the image\n' "$label"
}

step "--prebuilt --image <file> --trust-key"
run_install "$d_stick\n" --prebuilt --image "$vm_pb" --trust-key "$pub" "${pbargs[@]}" "/dev/$d_stick"
grep -q "Wrote and verified /dev/$d_stick" "$vm/last.txt" || die "--prebuilt --image did not report a verified write"
grep -q 'Wrote and verified the key record' "$vm/last.txt" || die "--prebuilt --image did not report a verified record"
grep -q 'Wrote and verified the repository header and asset' "$vm/last.txt" || die "--prebuilt --image did not report a verified repository asset"
grep -q 'repository asset: signature ok, sha256 ok, belongs to this image' "$vm/last.txt" || die "the asset's checks were not reported"
grep -q 'whoever holds the stick holds the key' "$vm/last.txt" || die "the key notice was not shown"
! grep -qF -f "$stub_cfg/api-key" "$vm/last.txt" || die "install.sh printed the key"
check_prebuilt_stick "--prebuilt --image"

step "--wipe, then --prebuilt --base-url from a local server"
run_install "$d_stick\n" --wipe "/dev/$d_stick"
vm_ssh root sync
img_zero "$vm/stick.img" || die "the stick is not zero after --wipe"
vm_ssh builder 'cd /big/pb && (nohup python3 -m http.server 8000 --bind 127.0.0.1 > /big/tmp/http.log 2>&1 < /dev/null & echo $! > /big/tmp/http.pid)'
sleep 2
run_install "$d_stick\n" --prebuilt "$sig_ver" --base-url http://127.0.0.1:8000 --trust-key "$pub" "${pbargs[@]:2}" "/dev/$d_stick"
# shellcheck disable=SC2016  # expanded in the VM
vm_ssh builder 'kill $(cat /big/tmp/http.pid)' || true
grep -q 'Downloading http://127.0.0.1:8000/' "$vm/last.txt" || die "--base-url did not download"
grep -q 'Wrote and verified the key record' "$vm/last.txt" || die "--prebuilt --base-url did not report a verified record"
grep -q "signature: ok (minisign, .*; version $sig_ver)" "$vm/last.txt" || die "--prebuilt $sig_ver did not print the verified version"
printf 'PASS: --prebuilt %s printed the verified version (%s)\n' "$sig_ver" "$(grep -m1 'signature: ok' "$vm/last.txt")"
grep -q "Downloading http://127.0.0.1:8000/.*$repo_name" "$vm/last.txt" || die "--prebuilt --base-url did not name the repository asset"
grep -q 'Wrote and verified the repository header and asset' "$vm/last.txt" || die "--prebuilt --base-url did not report a verified repository asset"
check_prebuilt_stick "--prebuilt --base-url"

step "a damaged asset, and a header of another image, boot online only"
off=$(( (pb_size + mib - 1) / mib * mib ))
keep_hdr=$work/out/stick-header.bin
stick_peek "$vm/stick.img" $(( off + mib )) $mib > "$keep_hdr"
copy=$work/out/stick-damaged.img
cp --sparse=always -- "$vm/stick.img" "$copy"
python3 -I - "$copy" $(( off + 2 * mib + pb_repo_size / 2 )) <<'PY'
import sys
with open(sys.argv[1], "r+b") as f:
    f.seek(int(sys.argv[2])); b = f.read(1); f.seek(int(sys.argv[2])); f.write(bytes([b[0] ^ 0xFF]))
PY
RESCUE_EXPECT_RECORD=1 RESCUE_EXPECT_REPO=none RESCUE_EXPECT_REPO_WHY=damaged RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$copy"
rm -f -- "$copy"
printf 'PASS: a stick whose asset has one byte changed boots online only and says the repository is damaged\n'

step "--prebuilt with the bare image over the stick: the stale repository is ignored"
vm_ssh builder "cd /big/bare-out && minisign -S -W -s /big/pb-bad/key-a.sec -t '$(tcomment "$pb_name" "$sig_ver")' -m $bare_name -x $bare_name.minisig > /dev/null"
run_install "$d_stick\n" --prebuilt --image "/big/bare-out/$bare_name" --no-repo --trust-key "$pub" --key-file "$vm_cfg/api-key" \
    --ssh-key "$vm_cfg/id_ed25519.pub" --endpoint "https://10.0.2.2:$stub_port/v1" --key-prefix sk- "/dev/$d_stick" > /dev/null
grep -q 'No repository asset (--no-repo)' "$vm/last.txt" || die "--no-repo did not say that the stick works online only"
grep -q "Wrote and verified /dev/$d_stick" "$vm/last.txt" || die "the bare --prebuilt write did not verify"
! grep -q 'repository header and asset' "$vm/last.txt" || die "--no-repo wrote a repository"
vm_ssh root sync
bare_size=$(vm_ssh builder "stat -c %s /big/bare-out/$bare_name")
bare_off=$(( (bare_size + mib - 1) / mib * mib ))
for i in $(seq 0 40); do
    o=$(( (bare_off / mib - 4 + i) * mib ))
    (( o >= bare_size )) || continue
    [[ $(stick_peek "$vm/stick.img" "$o" 8) != RSCREPO1 ]] || die "a repository header is still at byte $o after the rewrite"
done
[[ $(stick_peek "$vm/stick.img" "$off" 8) != RSCREPO1 && $(stick_peek "$vm/stick.img" $(( off + mib )) 8) != RSCREPO1 ]] || die "the old header survived"
printf 'PASS: after the rewrite no repository header is on the stick (the old one was at byte %s)\n' "$(( off + mib ))"
copy=$work/out/stick-stale.img
cp --sparse=always -- "$vm/stick.img" "$copy"
RESCUE_EXPECT_RECORD=1 RESCUE_EXPECT_REPO=none RESCUE_EXPECT_REPO_WHY="no offline repository" RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$copy"
printf 'PASS: the rewritten stick ignores the stale repository: online only, the reason shown\n'
# The old image'"'"'s header, put back by hand where this image'"'"'s would be.
dd if="$keep_hdr" of="$copy" bs=1M seek=$(( bare_off / mib + 1 )) count=1 conv=notrunc status=none
RESCUE_EXPECT_RECORD=1 RESCUE_EXPECT_REPO=none RESCUE_EXPECT_REPO_WHY="belongs to another image" RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$copy"
rm -f -- "$copy" "$keep_hdr"
printf 'PASS: a header naming another image is ignored: online only, "belongs to another image"\n'

step "a key-less stick with no record still asks for the key at tty1"
run_install "$d_stick\n" --iso "/big/bare-out/$bare_name" "/dev/$d_stick"
grep -q "Wrote and verified /dev/$d_stick" "$vm/last.txt" || die "the bare write did not verify"
vm_ssh root sync
bare_copy=$work/out/stick-bare.img
cp --sparse=always -- "$vm/stick.img" "$bare_copy"
bare_log=$(RESCUE_EXPECT_REPO=none RESCUE_CONFIG=$stub_cfg RESCUE_PROVIDER_STUB=$stub_cfg "$here/tests/qemu-boot.sh" "$bare_copy")
rm -f -- "$bare_copy"
printf '%s\n' "$bare_log" | grep -q 'key-at-boot: tty1 asks for the key' || die "the bare stick did not show tty1's key prompt"
printf 'PASS: the key-less stick with no record boots to tty1'"'"'s key prompt, takes the typed key and runs the agent\n'

step "no copy of the scratch key"
key_sha=$(sha256sum "$stub_cfg/api-key" | cut -d' ' -f1)
leaks=$(vm_ssh root "find / /big -xdev -type f -size +40c -size -60c -not -path '/home/builder/config/*' -not -path '/home/builder/config-nokeys/*' -not -path '/proc/*' -exec sha256sum {} + 2> /dev/null | grep -c '$key_sha' || true")
(( leaks == 0 )) || die "$leaks files of the VM hold the scratch key"
leaks=$(vm_ssh root "grep -rlF -f /home/builder/config/api-key /var/tmp /tmp /big/tmp /big/pb /run 2> /dev/null | wc -l")
(( leaks == 0 )) || die "grep finds the key's bytes in $leaks files of the VM's scratch areas"
printf 'PASS: no file on the VM'"'"'s file systems has the scratch API key'"'"'s sha256 outside the stub configuration, and grep -rlF finds no key bytes in its scratch areas\n'

step "--wipe after the prebuilt stage"
run_install "$d_stick\n" --wipe "/dev/$d_stick"
vm_ssh root sync
img_zero "$vm/stick.img" || die "the stick image has a non-zero byte after --wipe"
printf 'PASS: after --wipe the stick image has no non-zero byte (the record is gone)\n'
printf '\nPASS: the prebuilt stage\n'
