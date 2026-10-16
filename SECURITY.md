# Security policy

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the
repository's **Security** tab, then **Report a vulnerability**. Do not open a
public issue for it. Say what you found, how to reproduce it and what it puts
at risk. You will get an answer, and the fix is credited to you unless you ask
otherwise.

## In scope

The threats in [docs/threat-model.md](docs/threat-model.md), in particular:

- the repair agent writing to a disk, file system, partition table or boot
  entry against the guardrails of its brief (`profile/airootfs/root/rescue/AGENTS.md`),
  above all without the owner's on-screen OK where the brief requires one;
- text on the repaired machine that steers the agent into acting on it;
- the API key reaching the agent, a log, the build tree outside its root-only
  file, the repository or anything the agent sends the provider;
- a disk or Wi-Fi passphrase, or a secret file from the machine, reaching the
  provider;
- a way to log in to the stick over SSH other than an authorized key;
- `install.sh` or `write-stick.sh` writing to a disk that is not a removable USB
  stick;
- `install.sh --prebuilt` writing an image or repository asset that fails its
  signature, checksum or image check.

## Out of scope

- The accepted risks the threat model names: a root agent reading the stick's
  raw blocks, whoever holds the stick holding its key, and the provider seeing
  what the agent sends it.
- A machine whose firmware, boot loader or kernel is already compromised, and
  Secure Boot, which the stick does not support.
- Vulnerabilities in Arch Linux's packages, OpenCode or the model provider
  themselves: report those upstream.
