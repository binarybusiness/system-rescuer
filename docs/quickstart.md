# Quickstart

From nothing to a rescue stick, then what to do at the broken machine. There
are two ways to a written stick:

- **A. A prebuilt image** (no build): download the signed image, check it, and
  write it with only your API key added. Needs a few small tools and about
  3 GB of downloads.
- **B. A build from the clone**: build the image yourself, with your SSH keys
  and machine profiles inside. Needs about 16 GiB of free disk (under
  Docker's data directory, usually `/var/lib/docker`, and the clone's
  `out/`) and from a few minutes to half an hour, mostly downloading
  packages.

Both end with the same stick. Each command below runs in the clone, as your
own user (not root); the scripts ask for sudo themselves when they need it.

## What you need

- **The broken machine**: x86_64 with UEFI firmware. Secure Boot must be off
  to start the stick (it is not signed for Secure Boot). Legacy BIOS, ARM and
  Apple Silicon machines are not supported.
- **A USB stick of 4 GB or more.** Everything on it is overwritten.
- **A Linux workstation** (x86_64) to write the stick, with sudo and `git`.
  Any distribution for path A; for path B, Arch Linux, or any distribution
  with Docker or rootful podman.
- **An API key for the model.** The default is DeepSeek V4.1 Flash: create a
  key at the DeepSeek platform (platform.deepseek.com) and add a small
  credit; a repair on the project's test bench costs US$0.04 to 0.08, and a
  long one on a real machine somewhat more. Use a key only for this stick, so
  you can revoke it if the stick is lost. Any other OpenAI-compatible
  provider works too (see "Another provider" below).
- **Internet at the broken machine**: a network cable, Wi-Fi, or a phone's USB
  tethering. The model runs online; the stick's own package repository works
  offline.

Get the code:

```sh
sudo apt update && sudo apt install git   # if git is missing (dnf or pacman elsewhere)
git clone <this repository's URL> system-rescuer
cd system-rescuer
```

## A. A prebuilt image

1. Install the tools: `minisign`, `curl`, `sha256sum` and `lsblk`
   (coreutils and util-linux, already installed almost everywhere).

   ```sh
   sudo apt update && sudo apt install minisign curl   # Debian, Ubuntu
   sudo dnf install minisign curl        # Fedora
   sudo pacman -S --needed minisign curl # Arch
   ./install.sh --check --prebuilt       # says what is still missing
   ```

2. Plug in the stick, and write it:

   ```sh
   ./install.sh --prebuilt
   ```

   It downloads the latest release's image and its offline package
   repository, each with its `.sha256` and `.minisig`, and checks each one's
   signature against the release key pinned in `install.sh`, then its
   sha256, before anything is written. It prints the verified version
   (`signature: ok (minisign, the pinned release key; version vN.N.N)`).
   `./install.sh --prebuilt v1.2.3` asks for one version and refuses any
   other.

3. It asks for the API key; type or paste it (nothing is shown) and press
   Enter, or name a file that holds it with `--key-file <file>`. To follow
   the repair from this workstation over SSH, add your SSH public key:
   `./install.sh --prebuilt --ssh-key ~/.ssh/id_ed25519.pub`.

4. It lists the USB sticks it found and asks which one; or name it,
   `./install.sh --prebuilt /dev/sdX`. It writes only to a whole, removable
   USB disk that nothing has mounted, shows its model, serial and size, and
   writes only once you type the device's name back (`sdX`, without
   `/dev/`). That question always needs a terminal: no option skips it. Then
   it writes the image, reads it back against its sha256, and writes your
   key, SSH key and the package repository past the image.

The key is stored on the stick **unencrypted**: whoever has the stick has the
key. `./install.sh --wipe /dev/sdX` erases the stick, key included.

### Check the image by hand

`install.sh` does this for you; to do it yourself, download both assets from
the release page, each with its `.sha256` and `.minisig`, and run:

```sh
minisign -V -P RWQqUFAm6iljYbnTwJgFKElY6U5QwYX4X9rM/r6XoBkHbMxuxWCVVRSj -m system-rescuer-x86_64.iso
minisign -V -P RWQqUFAm6iljYbnTwJgFKElY6U5QwYX4X9rM/r6XoBkHbMxuxWCVVRSj -m system-rescuer-x86_64-repo.img
sha256sum -c system-rescuer-x86_64.iso.sha256 system-rescuer-x86_64-repo.img.sha256
```

Each `minisign` line must say `Signature and comment signature verified` and
print a trusted comment naming that file and the release's version, such as
`file:system-rescuer-x86_64.iso	version:v1.2.3`. The release key's id is
`616329EA2650502A`; the README and each release's note print the same key.
Then `./install.sh --prebuilt --image system-rescuer-x86_64.iso --repo
system-rescuer-x86_64-repo.img` writes those files.

### Before the first release: an image you sign yourself

No image is published yet. Until there is one, build the key-less image
yourself and sign it with a minisign key of your own; this takes the place
of steps 2 to 4 above:

1. Install step 1's tools above (minisign and curl; its `./install.sh
   --check --prebuilt` may run too, and checks only the write's tools) and
   path B's step 1 (the build tools: Docker, unless the host is Arch, and
   the new login it asks for).
2. Do path B's step 2, the configuration, and its `./install.sh --check`:
   that is the check for a build. The image takes your SSH keys
   (`authorized_keys`), machine profiles and any `provider_*` settings from
   the configuration, but no API key (a `key_file` there is ignored): the
   key goes on the stick only when you write it, with the last command
   below. The provider settings are fixed when the image is built, so set
   any `provider_*` now, as B2 shows: for a provider with its own CA, both
   the `provider_*` lines and the copy of the CA's PEM file into the
   configuration directory. The write checks your key against the image's
   `provider_key_prefix` (by default `sk-`), so set that too if your key
   starts otherwise (empty, `provider_key_prefix=`, when you do not know).
3. Build, sign and write, from the clone. The later commands use `$iso` and
   `$repo`; in a new shell (after a build in `tmux`, say), set them again
   with the `iso=` and `repo=` lines.

```sh
./install.sh --build-only --no-key --repo-asset --out-dir out/prebuilt
minisign -G -W -p my-release.pub -s my-release.key          # a key pair, no password
iso=$(ls out/prebuilt/system-rescuer-*-x86_64.iso)          # e.g. system-rescuer-2026.10.15-x86_64.iso
repo=${iso%.iso}-repo.img
minisign -S -s my-release.key -m "$iso" -t "$(printf 'file:system-rescuer-x86_64.iso\tversion:v0.0.0')"
minisign -S -s my-release.key -m "$repo" -t "$(printf 'file:system-rescuer-x86_64-repo.img\tversion:v0.0.0')"
./install.sh --prebuilt --image "$iso" --repo "$repo" --trust-key my-release.pub /dev/sdX
```

The build leaves in `out/prebuilt` the image and the repository, each with
its `.sha256` (which `install.sh` needs beside it), plus its build log and a
few small marker files. The last command asks for the API key (or takes
`--key-file <file>`) and writes the stick as in step 4: `/dev/sdX` is your
stick (leave it out to choose from a list), and the typed-back name needs a
terminal (over SSH, `ssh -t`): it is read from the terminal, not from
standard input, so no script or pipe can answer it, by design. The image
already carries the keys of your `authorized_keys`, and `--ssh-key` would
add one more; the `record:` line counts only the ones added. `--trust-key` trusts your key instead of the pinned release key, and
says so; it is for this kind of test only. To check these files by hand as
above, in the same shell, name your public key file with `-p
my-release.pub` (the same key `-P` takes as text):

```sh
minisign -V -p my-release.pub -m "$iso"
minisign -V -p my-release.pub -m "$repo"
(cd out/prebuilt && sha256sum -c "${iso##*/}.sha256" "${repo##*/}.sha256")
```

The trusted comment names the release's undated file name all the same.

### Another provider

`--endpoint https://host/v1` points the stick at another OpenAI-compatible
API (https only) whose certificate a public CA signs, and
`--key-prefix <text>` makes the stick refuse a key that does not start with
it. The model's name and limits are the image's. A provider with a private
CA, or another model, needs an image built with `provider_*` in the
configuration (`provider_ca_file`, `provider_model` and the rest; B2 has
an example): path B, or the image you sign yourself above, then no
`--endpoint`. Unless you set
`provider_model`, the image asks for DeepSeek's model id, `deepseek-flash`,
so another provider needs its own model id there. Its documentation names
its ids, as does its `/v1/models` listing, without putting the key on a
command line:

```sh
curl --cacert provider-ca.pem -H @<(printf 'Authorization: Bearer %s\n' "$(cat ~/my-api-key)") \
    https://llm.example.net/v1/models
```

The build checks only the values' form, so a model id the provider does not
know shows at the stick's first request, and correcting it means building
the image again.

## B. A build from the clone

1. Install a build path:

   ```sh
   sudo pacman -S --needed archiso gitleaks libisoburn   # Arch: builds natively
   sudo apt update && sudo apt install docker.io         # elsewhere: Docker (or rootful podman)
   sudo usermod -aG docker "$USER"                       # then log in again: a new login or SSH session
   ```

   On Arch with those three packages the build runs natively under sudo;
   anywhere else it runs in a privileged `archlinux` container. Rootless
   Docker and rootless podman cannot build it. The `docker` group counts
   only from the next login: `permission denied` on Docker's socket means a
   shell from before it (log in again, or run `newgrp docker`; for one
   command, `sg docker -c './install.sh --check'` runs it in the group
   without either).

2. Make your configuration from the example, in the clone:

   ```sh
   mkdir -p ~/.config/system-rescuer
   cp -r examples/config/. ~/.config/system-rescuer/        # again later, it overwrites your edits
   mkdir -p -m 700 ~/.ssh
   test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # an SSH key, if you have none (to log in to the stick; step 4's check needs one without a passphrase, or in ssh-agent)
   cat ~/.ssh/id_ed25519.pub >> ~/.config/system-rescuer/authorized_keys
   ./install.sh --check                                  # the host check: says what is still missing
   ```

   For a provider with its own CA, copy the CA's PEM file in (below) before
   this check, which reports whether it is readable.

   The host check says where the build needs its free space (the build
   tree, or Docker's data directory, usually `/var/lib/docker`, and `out/`,
   which `--out-dir <dir>` moves) and how much is free on each, where the key comes from, which
   provider and model the image will use, whether the provider's CA file is
   readable, and how many SSH keys the stick will take.

   - `authorized_keys`: the SSH public keys that may log in to the stick as
     root, to follow the repair from another machine (the line above creates
     it; `authorized_keys.example` only shows the format). Without it, the repair
     is followed on the broken machine's own screen.
   - `rescue.conf`: where the API key comes from (`key_file=` or
     `key_command=`; with neither, the build asks for it), `ssh_identity=`
     (the private half of that SSH key; only step 4's check uses it, so
     it can stay unset if you skip that step), and optionally another
     provider (`provider_*`). Each setting is explained in the file; remove
     the `#` to set one, or add the line at the end (the last line of a name
     wins). For example, for a self-hosted provider whose certificate your
     own CA signs (copy the CA's PEM file into this directory; a container
     build sees nothing outside it):

     ```sh
     cp <your CA's PEM file> ~/.config/system-rescuer/provider-ca.pem   # beside rescue.conf
     ```

     ```
     key_file=~/my-api-key
     ssh_identity=~/.ssh/id_ed25519
     provider_url=https://llm.example.net/v1
     provider_model=<the model id your provider serves>
     provider_ca_file=provider-ca.pem
     ```

     Without `provider_model`, the image asks for DeepSeek's
     `deepseek-flash`. The provider's documentation names its model ids, as
     does its `/v1/models` listing for most OpenAI-compatible servers. The
     other `provider_*` settings default to DeepSeek's too: set
     `provider_model_name` (the name the agent's screen shows),
     `provider_context` and `provider_output` (the model's token limits,
     which the agent uses to size its context) and the `provider_cost_*`
     prices (only for the cost it shows) to your model's, and
     `provider_key_prefix=` (empty) if your key does not start with `sk-`
     or you do not know how it starts,
     since the build refuses one that does not (and so does the write of a
     key-less image built with it, as in "Before the first release" above).

   - `machines/`: what the agent should know about your own machines (see
     `profile/airootfs/root/rescue/machines/README.md`). The example profile
     matches only the project's test disk, so it can stay or go.

3. Plug in the stick, and build and write it:

   ```sh
   ./install.sh /dev/sdX
   ```

   `/dev/sdX` is your stick; leave it out to choose from a list of the USB
   sticks it finds (`lsblk -o NAME,SIZE,TRAN,MODEL` shows them too: the
   stick is the `usb` one). It checks the host, builds the image (the ISO
   and its sha256 in `out/`; a quiet minute after `build.sh: built`, then
   `checking the ISO against ...`), then writes the stick as in path A, step
   4 (with `key_file=` or `key_command=` set, it does not ask for the key),
   and reads it back against the sha256; `Wrote and verified /dev/sdX.` means it is done. The key is
   inside the image, unencrypted. The build checks only the key's form; the
   stick checks the key with the provider when it boots.

   The device question comes after the build and needs a terminal: over SSH,
   use `ssh -t`, and run a long build in `tmux` or `screen` so a dropped
   connection does not stop it (`tmux new -s build`, then run it there;
   `tmux attach -t build` gets back to it). If you mistype the name, nothing is written
   and the image stays in `out/`:
   `./install.sh --iso out/system-rescuer-<date>-x86_64.iso /dev/sdX` writes
   it without building again.

   Other ways: `./install.sh --build-only` builds without writing (an
   unattended build), then
   `./install.sh --iso out/system-rescuer-<date>-x86_64.iso /dev/sdX` writes
   it; `./install.sh --build-only --no-key` builds an image with no key, and
   the stick then asks for the key at boot instead. `./install.sh --clean`
   removes the build tree and any copy of the key a build left behind.

4. Optionally, boot the image under qemu before you need it:

   ```sh
   sudo pacman -S --needed qemu-base edk2-ovmf   # Arch
   sudo apt update && sudo apt install qemu-system-x86 ovmf   # Debian, Ubuntu
   tests/qemu-boot.sh out/system-rescuer-<date>-x86_64.iso
   ```

   It boots the image, logs in over SSH with `ssh_identity` from
   `rescue.conf`, and checks that the agent starts with your key (so it
   calls the provider once, for a few tokens).

## At the broken machine

1. Plug the stick into the broken machine (a rear USB port on a desktop) and
   power on.
2. Open the firmware's boot menu (usually F8, F11 or F12 at the logo) and pick
   the **UEFI** entry for the USB stick. If Secure Boot is on, turn it off in
   the firmware settings first.
3. The stick's menu starts "system-rescuer" by itself after 3 seconds.
4. If no network address arrives within 60 s, the screen shows a network
   menu: a phone's USB tethering, a static address on a wired port, a Wi-Fi
   network (its passphrase is typed at the prompt and not shown), or waiting
   for a cable.
5. A stick with no key on it asks for the API key: type or paste it (nothing
   is shown). It stays only in memory. A key the provider refuses is asked for
   again.
6. Watch the screen. The stick checks the key, runs a read-only survey of the
   machine, and the repair agent starts: it diagnoses the fault, explains
   each step, and repairs. Type what you know at any time (an update that
   was cut off, a power cut, the error message you saw). Before a step that
   could lose data (a repairing fsck, recreating a backed-up EFI partition, a
   partition-table edit) it asks for your OK on that screen; answer there.
7. To follow from another machine:
   `ssh root@<address shown on the screen> -t tmux attach -t rescue`
   (detach with `Ctrl-b d`). It needs your SSH key on the stick (path A's
   `--ssh-key`, or path B's `authorized_keys`).
8. When the agent says it is done, remove the stick and reboot. Its log is
   `/root/rescue-log` on the stick while it runs; when the repaired system's
   root filesystem is writable, a copy is left at `/root/rescue-log` there.

On a machine with both Linux and Windows, say which system no longer
appears. If Windows uses BitLocker, have its recovery key ready: the agent
asks for an OK before it changes the firmware's boot entries, their order or
an EFI partition, because Windows may then ask for that key at its next
start. It never edits Windows' files or its boot configuration (BCD), mounts
Windows read-only, and leaves a hibernated Windows unmounted.

## Afterwards

- Revoke the API key at the provider if the stick leaves your hands, and
  `./install.sh --wipe /dev/sdX` before you reuse or give away the stick.
- The agent may leave notes in its handback, such as a configuration change
  the machine's owner should make for good; it does not make lasting changes
  itself beyond the repair.
- What the stick protects against, and what it does not, is in
  [the threat model](threat-model.md).
