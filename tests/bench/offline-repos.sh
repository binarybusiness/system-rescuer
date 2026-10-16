#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Run inside the rescue system by tests/scenario.sh --offline-repos (as
# BENCH=offline-repos bash -s), after SSH answers and before the agent starts:
# nftables lets out only DNS, DHCP and the model API (HTTPS to the addresses
# the configured model API's host resolves to now, for the key check, and anything from
# rescue-proxy's nginx workers, which run as an unprivileged user, should the
# API's addresses change), so every package mirror is unreachable, as on a
# network that reaches the API and nothing else. Replies from sshd pass by
# port: the bench's own session began before conntrack was loaded, and its
# packets are not tracked as established. rescue-proxy starts after
# network-online.target, so on a loaded host it can still be starting when SSH
# first answers: its workers get up to 120 s. Prints what it checked; exit
# status 1 when the network is not as intended.
set -euo pipefail

worker=''
for (( i = 0; i < 60; i++ )); do
    worker=$(pgrep -a -x nginx | awk '/worker process/ {print $1}' | head -n 1)
    [[ -z $worker ]] || break
    sleep 2
done
[[ -n $worker ]] && worker=$(ps -o user= -p "$worker" | tr -d ' ')
[[ -n $worker && $worker != root ]] || { echo "rescue-proxy's nginx has no unprivileged worker after 120 s"; exit 1; }
api_host=$(sed -n 's/^host=//p' /etc/rescue/provider.conf)
[[ -n $api_host ]] || { echo "no host in /etc/rescue/provider.conf"; exit 1; }
v4=$(getent ahostsv4 "$api_host" | awk '{print $1}' | sort -u | paste -sd, -)
[[ -n $v4 ]] || { echo "$api_host does not resolve"; exit 1; }
nft -f - <<EOF
table inet bench_offline {
    chain output {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        ct state established,related accept
        tcp sport 22 accept
        udp dport { 53, 67 } accept
        tcp dport 53 accept
        ip daddr { $v4 } tcp dport 443 accept
        meta skuid "$worker" accept
    }
}
EOF

mirror=https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db
if curl -sS -o /dev/null --max-time 15 "$mirror" 2>/dev/null; then
    echo "a mirror still answers ($mirror)"; exit 1
fi
api=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 http://127.0.0.1:8484/v1/models 2>/dev/null) || api=000
[[ $api == 200 ]] || { echo "the model API through rescue-proxy answers $api, not 200"; exit 1; }
echo "nftables lets out only DNS, DHCP, sshd's replies, HTTPS to $api_host ($v4) and rescue-proxy ($worker): the mirrors are unreachable, the model API answers 200"
