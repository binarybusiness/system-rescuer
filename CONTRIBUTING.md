# Contributing

system-rescuer builds an Arch Linux rescue stick for x86_64 UEFI machines,
with a repair agent on it. A change can break a machine that is already
broken, so every change goes through review, and some need evidence from a
run under qemu. This page says which checks a change needs, what they cost,
and how a pull request is merged.

Report a vulnerability privately, as [SECURITY.md](SECURITY.md) says, not in
an issue or a pull request.

## Before you open a pull request

Every change passes the static checks. CI runs them on every pull request:

```sh
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -r shellcheck
tests/spdx-check.sh && tests/spdx-check-test.sh   # every source file names its licence
tests/workflow-check.sh && tests/workflow-check-test.sh   # no fork's pull request reaches a self-hosted runner (needs PyYAML)
python3 tests/bench/guardrails.py --check-brief   # the guardrail oracle covers every hard rule of the brief
python3 tests/bench/playbooks-check.py            # every command of the disk playbooks passes the oracle
tests/leak-check.sh --tree . --paths tests/public-paths && tests/leak-check-test.sh   # no personal data in what ships
python3 tests/link-check.py .                     # every relative Markdown link resolves inside the tree
```

A change to the image (`profile/`, `build.sh`, `lib/`) also needs a boot
check, which needs KVM and OVMF, so CI does not run it. Build an ISO and boot
it:

```sh
sudo pacman -S --needed archiso shellcheck qemu-base edk2-ovmf
./install.sh --build-only                # or sudo ./build.sh on Arch
tests/qemu-boot.sh out/system-rescuer-*.iso
```

You can build and check the image without a real API key: the stub mode
(`RESCUE_PROVIDER_STUB=<config dir>`, set up as the header of
`tests/qemu-boot.sh` describes) runs a local stand-in for the provider. Say in
the pull request which checks you ran, and paste their summary lines.

## The scenario bench

A change to what the agent is told or allowed to do needs the scenario bench
(`tests/scenario.sh`, `tests/scenario-matrix.sh`; the README's bench section
describes them). The bench plants a fault in a real installed system under
qemu, lets the stick repair it and judges the result. It needs root, KVM,
tens of GiB of disk for the cached systems (more with the Windows 11
evaluation image), and an API key of your own.
The model's cost is yours:

- One scenario run costs about US$0.04 to 0.08 with the default model
  (DeepSeek V4.1 Flash), and takes 3 to 5 minutes.
- The whole matrix (every scenario on every system, three runs of each
  guardrail scenario) cost US$6.59 for 105 runs.
- `sudo tests/scenario-matrix.sh --dry-run` projects the cost before
  anything runs. The matrix refuses to start above `--budget` (US$100 by
  default), and `--only` keeps the scenarios a change touches.

Run the scenarios the change touches, and say which in the pull request.

## The brief and the guardrails

The agent's brief and playbooks (`profile/airootfs/root/rescue/`) are reviewed
like code. The agent works as root on a disk it may not get back, so the rules
of the brief are the product's safety boundary:

- A change to a hard rule of the brief (read-only until diagnosed, no writes
  to a failing disk, no mkfs except of a backed-up ESP, no
  `btrfs check --repair`, no repairing fsck or partition-table edit without
  the owner's on-screen OK) comes with the matching case in
  `tests/bench/guardrails.py`. `--check-brief` fails when a rule has none.
- A change to `tests/bench/guardrails.py` is followed by
  `python3 tests/bench/guardrails-replay.py`, which judges the recorded runs
  again. Explain every verdict that changes.
- A change that lets the agent do more needs a guardrail scenario (group B in
  `tests/scenarios/`) that passes three times out of three.
- The disk playbooks in `profile/airootfs/root/diskrepair-playbooks/`, where
  present, are copied unchanged from another project and are never edited
  here. Report a problem with them in an issue.

## Secrets and personal data

Never commit a key, a password or a machine's own configuration. The stick's
configuration lives outside the repository (`~/.config/system-rescuer/`;
`examples/config/` is the example to start from). Turn on the repository's
hooks with `git config core.hooksPath .githooks`, so gitleaks checks every
commit. `tests/leak-check.sh --tree . --paths tests/public-paths` looks for
personal data, such as home directories and addresses, in the part that
ships.

## Licence

Contributions are under the GNU General Public License, version 3 or (at
your option) any later version, as the rest of the project
([LICENSE](LICENSE)). A new source file starts with an
`SPDX-License-Identifier: GPL-3.0-or-later` line (after its shebang), which
`tests/spdx-check.sh` checks. Code from elsewhere needs a licence compatible
with that, and an entry in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## How a pull request is merged

A maintainer reviews it here, in public, and merges it here once its checks
pass. CI's workflows for a first-time contributor wait for a maintainer's
approval before they run. The maintainer then carries the merged change into
their working copy, so the next update of this repository keeps it.
