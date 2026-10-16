# Machine profiles

One directory per known machine. `rescue-survey` compares the filesystem
UUIDs it finds with each machine's `match` file and names the machine whose
identifiers are present.

- `match`: one filesystem UUID per line (`blkid -s UUID -o value`); lines
  starting with `#` are comments.
- `profile.md`: what the agent should know — the disk layout by UUID, the
  disks it must not touch, how this machine's boot chain is repaired, and its
  history of past incidents.
- Any copies of the machine's configuration that help a repair. Never copy
  secrets, keys or git-crypt files.

A profile is context, not a script: the agent still diagnoses from evidence,
and the guardrails in `../AGENTS.md` still apply.
