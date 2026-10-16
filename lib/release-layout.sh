# shellcheck shell=bash disable=SC2034  # the sourcing script reads these
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# The layout of a release, stated once: the key that signs it and the assets
# it publishes. install.sh checks a download against it, and
# release/build-image.sh reads it from the tagged tree and refuses to sign
# with any other key, so every release verifies with the installer it ships.
# docs/quickstart.md and README.md print the key; tests/release-test.sh
# checks that they print this one.

# The release public key (minisign key id 616329EA2650502A), the base64 line
# of its .pub file. Every release's notes print it too.
release_pubkey=RWQqUFAm6iljYbnTwJgFKElY6U5QwYX4X9rM/r6XoBkHbMxuxWCVVRSj
# The public repository, its release URL, and the identity used for its
# scrubbed snapshot commits. Keep the name here so changing it is one edit.
public_repo=binarybusiness/system-rescuer-public
release_url=https://github.com/$public_repo/releases
public_author='binarybusiness <81260583+binarybusiness@users.noreply.github.com>'
# The assets of a release, each with <name>.sha256 and <name>.minisig; the
# version is the release's tag.
release_iso=system-rescuer-x86_64.iso
release_repo=system-rescuer-x86_64-repo.img
