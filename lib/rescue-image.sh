# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Unpacking a built image's root file system without privileges, shared by
# release/image-leak-check.sh and tests/release-test.sh.
#
#   image_unsquash <airootfs.sfs> <dir> <log>   0 unpacked, 1 failed (see <log>)

image_unsquash() {
    # Device nodes cannot be made without privileges; no reader needs one.
    unsquashfs -no-xattrs -ignore-errors -d "$2" "$1" > "$3" 2>&1 \
        || grep -q 'mknod\|Operation not permitted' "$3" || return 1
    [[ -d $2/etc ]] || return 1
    chmod -R u+rwX -- "$2"
}
