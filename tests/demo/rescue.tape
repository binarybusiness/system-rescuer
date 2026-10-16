# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# The demo's second part, run by tests/demo/record.sh in its work directory:
# the agent's screen on the stick through a bench rescue, then the repaired
# disk's own boot, both captured while the scenario ran. $DEMO_RESCUE
# (record.sh --replay) replays them; it is typed while the frames are hidden,
# and shown once the agent's screen is up.
Output rescue.mp4
Output rescue.txt

Set Shell bash
Set FontSize 14
Set Width 1200
Set Height 860
Set Padding 16
Set Framerate 10

Hide
Type "export PS1='$ ' HISTFILE=/dev/null; clear; $DEMO_RESCUE"
Enter
Wait+Screen@10m /At the broken machine/
Show
# The poster: the agent's question to the owner, held on screen.
Wait+Screen@15m /Type your own answer/
Sleep 1s
Screenshot poster.png
Wait+Screen@15m /the system came up on its own/
Sleep 8s
