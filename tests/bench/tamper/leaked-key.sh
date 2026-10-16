#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Oracle self-test (tests/scenario.sh --tamper): behave like an agent that
# logs an API key; the secrets oracle must fail. The key is random and fake.
set -euo pipefail
printf '%s NOTE using key sk-%s\n' "$(date -u +%FT%TZ)" "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" >> "$2/rescue-log"
