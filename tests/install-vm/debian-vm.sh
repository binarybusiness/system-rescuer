# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# The scratch Debian VM that tests/install-vm.sh and tests/quickstart-vm.sh
# boot and provision the same way: an overlay on the cached Debian image, qemu
# with KVM and user-mode networking, one serial-console provisioning session,
# and an SSH wait. No function calls the caller's die(); each returns non-zero
# and the caller dies with its own message.
#
#   debian_vm_boot <vm-dir> <port> <mem-MiB> [qemu-arg...]
#       Boots the VM with ssh on 127.0.0.1:<port>, the extra qemu arguments
#       (the caller's own disks and devices) after the root disk. Writes
#       <vm-dir>/{root.qcow2,vars.fd,serial.log,serial.sock,qemu.pid}. Returns
#       once the serial socket exists.
#   debian_vm_provision <vm-dir> <user> <pubkey> <hostname|''> [package...] < <shell lines>
#       One console.py session (stderr to <vm-dir>/console.log): the shell
#       lines on stdin first (the caller's scratch disk and mounts), then
#       openssh-server, sudo and the packages, a passwordless-sudo <user> and
#       the key for <user> and root, the hostname if given, and ssh enabled.
#   debian_vm_wait_ssh <command...>
#       Retries the command (a login that runs true) up to 60 times, 2 s apart.

debian_vm_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
base_image=$HOME/.cache/system-rescuer/downloads/debian-13-nocloud-amd64.qcow2
ovmf_code=/usr/share/edk2/x64/OVMF_CODE.4m.fd
ovmf_vars=/usr/share/edk2/x64/OVMF_VARS.4m.fd

debian_vm_boot() {
    local vm=$1 port=$2 mem=$3; shift 3
    # An overlay, so the cached image stays clean and the VM goes away with it.
    qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" "$vm/root.qcow2" || return 1
    cp -- "$ovmf_vars" "$vm/vars.fd" || return 1
    qemu-system-x86_64 -enable-kvm -cpu host -m "$mem" -smp 6 -nodefaults -display none \
        -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
        -drive if=pflash,format=raw,file="$vm/vars.fd" \
        -drive file="$vm/root.qcow2",if=virtio,format=qcow2 \
        "$@" \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$port"-:22 -device virtio-net-pci,netdev=n0 \
        -chardev "socket,id=ser0,path=$vm/serial.sock,server=on,wait=off,logfile=$vm/serial.log" -serial chardev:ser0 \
        -daemonize -pidfile "$vm/qemu.pid" || return 1
    until [[ -S $vm/serial.sock ]]; do sleep 0.5; done
}

debian_vm_provision() {
    local vm=$1 user=$2 pubkey=$3 host=$4; shift 4
    {
        cat
        cat <<EOT
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server sudo $*
useradd -m -s /bin/bash $user
echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user
install -d -m 700 -o $user -g $user /home/$user/.ssh
echo '$pubkey' > /home/$user/.ssh/authorized_keys
chown $user:$user /home/$user/.ssh/authorized_keys
${host:+hostnamectl set-hostname $host; echo 127.0.1.1 $host >> /etc/hosts}
install -d -m 700 /root/.ssh
echo '$pubkey' > /root/.ssh/authorized_keys
systemctl enable --now ssh
EOT
    } | python3 -I "$debian_vm_dir/console.py" "$vm/serial.sock" 900 2> "$vm/console.log"
}

debian_vm_wait_ssh() {
    local tries=0
    until "$@" 2> /dev/null; do
        (( ++tries < 60 )) || return 1
        sleep 2
    done
}
