#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# key-teardown.sh: run on the rescue system as root, piped over SSH (bash -s <
# key-teardown.sh), by tests/qemu-boot.sh. In a copy of the agent's mount
# namespace (private, so nothing it does reaches the system), it undoes every
# mount where a secret could hide, as an agent bent on finding one could: it
# rbinds /run into a directory, then unmounts each mount there and under
# /run, /var/lib and /root, deepest first, until none is left. Then it looks
# for the DeepSeek key (a file of the key's size and hash, compared here and
# never printed), rescue-proxy's auth.conf and iwd's saved networks anywhere
# but /proc, /sys and /dev. It prints one line and fails if it finds any.
set -uo pipefail
p=$(pgrep -of 'opencode --standalone') || { echo "no agent running"; exit 2; }
# The key, from the system's namespace, wherever this image keeps it.
k=''
for f in /run/.rescue-key/deepseek-key /root/.config/rescue/deepseek-key; do
    [[ -s $f ]] && { k=$f; break; }
done
[[ -n $k ]] || { echo "no key file in the system's namespace"; exit 2; }
size=$(stat -c %s "$k")
sum=$(sha256sum < "$k") sum=${sum%% *}
# shellcheck disable=SC2016  # expands in the copy of the agent's namespace
nsenter --mount="/proc/$p/ns/mnt" -- unshare --mount --propagation private \
    env SIZE="$size" SUM="$sum" bash -c '
        under="^(/tmp/teardown|/run|/var/lib|/root)(/|$)"
        mkdir -p /tmp/teardown && mount --rbind /run /tmp/teardown || { echo "could not rbind /run"; exit 2; }
        undone=0
        for _ in $(seq 20); do
            mapfile -t ms < <(findmnt -rn -o TARGET | grep -E "$under" | sort -r)
            (( ${#ms[@]} )) || break
            for m in "${ms[@]}"; do
                umount "$m" 2> /dev/null || umount -l "$m" 2> /dev/null && undone=$((undone + 1))
            done
        done
        left=$(findmnt -rn -o TARGET | grep -cE "$under")
        found=()
        while IFS= read -r -d "" f; do
            s=$(sha256sum < "$f") && [[ ${s%% *} == "$SUM" ]] && found+=("the key in $f")
        done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -type f -size "${SIZE}c" -print0 2> /dev/null)
        while IFS= read -r -d "" f; do
            found+=("$f")
        done < <(find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o \
                      \( -name "auth.conf*" -o -path "*/iwd/*.psk" -o -path "*/iwd/*.8021x" \) -print0 2> /dev/null)
        if (( ${#found[@]} )); then
            echo "after $undone unmounts ($left mounts left there): ${found[*]}"
            exit 1
        fi
        echo "after $undone unmounts ($left mounts left there), no key, auth.conf or saved network"
    '
