# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# The demo's first part, run by tests/demo/record.sh in its work directory:
# its caption ($DEMO_CARD), then install.sh --prebuilt writing the scratch
# VM's USB stick. $DEMO_VM logs in to the VM; the commands that print the
# caption and log in are typed while the frames are hidden.
Output install.mp4
Output install.txt

Set Shell bash
Set FontSize 14
Set Width 1200
Set Height 860
Set Padding 16
Set Framerate 10
Set TypingSpeed 40ms

Hide
Type "export PS1='$ ' HISTFILE=/dev/null; $DEMO_CARD"
Enter
Wait+Screen@30s /write the stick/
Show
Sleep 9s
Hide
Type "clear; $DEMO_VM"
Enter
Wait+Screen@60s /user@workstation/
Type "cd /work/system-rescuer && clear"
Enter
Sleep 1s
Show

Type "./install.sh --prebuilt --image system-rescuer-x86_64.iso --repo system-rescuer-x86_64-repo.img --trust-key demo-release.pub /dev/sda"
Sleep 800ms
Enter
# A dummy key: this stick is never booted, and the prompt shows none of it.
Wait+Screen@3m /typed text is not shown/
Sleep 2s
Type "sk-demo-not-a-real-key-0000"
Sleep 600ms
Enter
Wait+Screen@3m /Type the device name/
Sleep 2s
Type "sda"
Sleep 600ms
Enter
Wait+Screen@15m /repository header and asset past/
Sleep 5s
