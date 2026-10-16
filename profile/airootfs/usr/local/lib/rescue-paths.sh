# shellcheck shell=bash disable=SC2034  # read by the scripts that source it
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Where the API key and the boot-time state live: the one statement. Sourced by
# rescue-secrets, rescue-key-record, rescue-keycheck, rescue-proxy-conf and
# rescue-agent in the image (/usr/local/lib/), and from the clone by build.sh
# and tests/qemu-boot.sh.
#
#   build time   the key goes into the image at rescue_image_key
#   boot         rescue-secrets moves it to rescue_key_file, on a root-only
#                tmpfs at rescue_key_dir, and deletes the image's copy
#   key-less     rescue-key-record (a record past the image) or rescue-agent
#                (typed at tty1) writes rescue_key_file
#
# Places that cannot read this file and must change with it: profile/
# profiledef.sh (modes of the image path), airootfs/root/.config/opencode/
# opencode.json (deny rules), airootfs/etc/motd, airootfs/etc/rescue-proxy/
# nginx.conf (the auth.conf include), airootfs/etc/systemd/system/
# rescue-proxy.service (a comment), tests/bench/guardrails.py (API_KEY,
# KEY_SERVICES), tests/bench/key-teardown.sh, tests/install-vm.sh and the
# comments of the scripts above.

# The image's copy, built in by build.sh and removed at boot.
rescue_image_key_dir=/root/.config/rescue
rescue_image_key=$rescue_image_key_dir/deepseek-key

# The root-only tmpfs of its own that the agent's mount namespace unmounts.
rescue_key_dir=/run/.rescue-key
rescue_key_file=$rescue_key_dir/deepseek-key
rescue_auth_conf=$rescue_key_dir/auth.conf

# Boot-time state (not secret) and its markers.
rescue_state_dir=/run/rescue
rescue_key_at_boot=$rescue_state_dir/key-at-boot
rescue_provider_conf=/etc/rescue/provider.conf
