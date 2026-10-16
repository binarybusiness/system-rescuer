#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# The bench's Wi-Fi network (tests/scenario.sh, a scenario's wifi=ap). Run on
# the rescue system as `env BENCH=wifi-ap bash -s < wifi-ap.sh`, once the
# network's passphrase is in /run/bench-wifi/pass (root-only, copied over
# SSH's stdin). mac80211_hwsim makes two radios. The second goes, with the
# wired NIC (the one that is not the bench's SSH NIC), into a network
# namespace of its own and becomes the access point "rescue-bench" (WPA2,
# addresses from dnsmasq, NAT out through the wired NIC); the first is left
# to iwd. The rescue system's only way out is then that Wi-Fi network.
#
# The passphrase is in no command line: bash's own builtins carry it from its
# file into the access point's configuration, and both files are deleted
# once the access point is up. iwd is stopped while the radios are made and
# moved: on exit it deletes the interfaces it created, even one that has
# moved into another namespace.
set -euo pipefail

dir=/run/bench-wifi ns=bench-ap ssid=rescue-bench bench_mac=52:54:00:be:0c:01
[[ -s $dir/pass ]] || { echo "no passphrase in $dir/pass"; exit 1; }
chmod 700 "$dir"

wired=''
for n in /sys/class/net/*; do
    if [[ -e $n/device && ! -d $n/wireless && $(< "$n/address") != "$bench_mac" ]]; then wired=${n##*/}; fi
done
[[ -n $wired ]] || { echo "no wired NIC besides the bench's"; exit 1; }

systemctl stop iwd
modprobe mac80211_hwsim radios=2
for _ in $(seq 20); do
    mapfile -t phys < <(find /sys/class/ieee80211 -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V)
    if (( ${#phys[@]} >= 2 )); then break; fi
    sleep 0.5
done
(( ${#phys[@]} >= 2 )) || { echo "mac80211_hwsim made no two radios"; exit 1; }
ap_phy=${phys[-1]}

ip netns add "$ns"
iw phy "$ap_phy" set netns name "$ns"
ip link set "$wired" netns "$ns"
in_ns() { ip netns exec "$ns" "$@"; }
ap=$(in_ns ls /sys/class/net | grep -v -x -e lo -e "$wired" -e hwsim0 | head -n 1 || true)
if [[ -z $ap ]]; then
    ap=bench-ap0
    in_ns iw phy "$ap_phy" interface add "$ap" type managed
fi
in_ns ip link set lo up
in_ns ip link set "$wired" up
in_ns ip address add 10.0.2.15/24 dev "$wired"
in_ns ip route add default via 10.0.2.2
in_ns ip address add 192.168.77.1/24 dev "$ap"
in_ns sysctl -q -w net.ipv4.ip_forward=1

umask 077
printf 'ctrl_interface=%s/ctrl\nap_scan=2\nnetwork={\n ssid="%s"\n mode=2\n frequency=2412\n key_mgmt=WPA-PSK\n proto=RSN\n pairwise=CCMP\n group=CCMP\n psk="%s"\n}\n' \
    "$dir" "$ssid" "$(< "$dir/pass")" > "$dir/ap.conf"
in_ns wpa_supplicant -B -i "$ap" -D nl80211 -c "$dir/ap.conf" -f "$dir/wpa.log"
for _ in $(seq 30); do
    if grep -q AP-ENABLED "$dir/wpa.log" 2>/dev/null; then break; fi
    sleep 0.5
done
rm -f "$dir/ap.conf" "$dir/pass"
grep -q AP-ENABLED "$dir/wpa.log" || { echo "the access point did not start: $(tail -n 3 "$dir/wpa.log" | tr '\n' ' ')"; exit 1; }
in_ns dnsmasq --port=0 --interface="$ap" --bind-interfaces --dhcp-range=192.168.77.50,192.168.77.150,12h \
    --dhcp-option=option:router,192.168.77.1 --dhcp-option=option:dns-server,10.0.2.3 \
    --pid-file="$dir/dnsmasq.pid" --dhcp-leasefile="$dir/leases"
in_ns nft -f - <<EOF
table ip bench_nat {
    chain post { type nat hook postrouting priority 100; oifname "$wired" masquerade; }
}
EOF

systemctl start iwd
for _ in $(seq 40); do
    station=$(networkctl list --no-legend --no-pager 2>/dev/null | awk '$3 == "wlan" {print $2; exit}')
    if [[ -n $station ]]; then break; fi
    sleep 0.5
done
[[ -n ${station:-} ]] || { echo "iwd made no Wi-Fi device"; exit 1; }
echo "Wi-Fi network $ssid (WPA2) up on $ap_phy with $wired behind it; the rescue system's $station is iwd's"
