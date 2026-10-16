# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Reading an ISO 9660 image's own descriptor, and what lies past its end.
# Sourced on both sides of the stick: by rescue-stick-find.sh in the image
# (/usr/local/lib/), and from the clone by lib/rescue-stick.sh and build.sh.
# They read with dd and od alone and need no mount. The layout past the image
# is in lib/rescue-stick.sh.
#
#   rescue_volume_end <dev-or-file>     the byte length of the ISO 9660 volume,
#                                       from its primary volume descriptor;
#                                       fails when there is none
#   rescue_volume_uuid <dev-or-file>    its UUID (archisosearchuuid's form):
#                                       the descriptor's modification date
#   rescue_scan_past <dev> <end> <re>   "<offset> <16 byte head>" of the first
#                                       of the 8 1 MiB boundaries from <end>
#                                       whose first 16 bytes match <re>

rescue_volume_end() {
    local -a b
    read -ra b < <(dd if="$1" bs=2048 skip=16 count=1 status=none 2> /dev/null | od -An -v -tu1 -w2048)
    (( ${#b[@]} >= 130 )) || return 1
    [[ ${b[0]} == 1 && ${b[1]} == 67 && ${b[2]} == 68 && ${b[3]} == 48 && ${b[4]} == 48 && ${b[5]} == 49 ]] || return 1
    printf '%s' $(( (b[80] + b[81] * 256 + b[82] * 65536 + b[83] * 16777216) * (b[128] + b[129] * 256) ))
}

rescue_volume_uuid() {
    local d
    d=$(dd if="$1" bs=1 skip=$((32768 + 830)) count=16 status=none 2> /dev/null | tr -d '\000')
    [[ $d =~ ^[0-9]{16}$ ]] || return 1
    printf '%s-%s-%s-%s-%s-%s-%s' "${d:0:4}" "${d:4:2}" "${d:6:2}" "${d:8:2}" "${d:10:2}" "${d:12:2}" "${d:14:2}"
}

rescue_scan_past() {
    local dev=$1 end=$2 re=$3 mib=1048576 first i o head
    first=$(( (end + mib - 1) / mib ))
    for i in 0 1 2 3 4 5 6 7; do
        o=$(( (first + i) * mib ))
        head=$(dd if="$dev" iflag=skip_bytes skip="$o" bs=16 count=1 status=none 2> /dev/null | tr -d '\000')
        if [[ $head =~ $re ]]; then printf '%s %s' "$o" "$head"; return 0; fi
    done
    return 1
}
