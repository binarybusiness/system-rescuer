# HDD slow or timing-out reads

Slug: `slow-reads`

## Triage

- From `inspect`: errors in the ATA error log or a failed read self-test with otherwise unchanged counts point at stalls and retries (weak sectors, a flaky cable or bridge, a failing head) rather than a surface already lost.
- Rule out the path first: a different cable, port or adapter; kernel log lines naming the link (reset, timeout) separate a path fault from the drive.
- Image first with a fast pass that gives up on slow areas quickly (`-n` and a no-progress timeout), then retries (`-r`). Every minute of stalling is wear.
- Do not run long self-tests or repeated read scans on a drive that is already timing out.

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in failing, watch; a reason contains one of 'errors in the ATA error log', 'latest self-test', 'timeout', 'slow'; priority 10 when several playbooks match.

## Register cases

- no register case yet

## Steps

1. Read the ATA error and self-test logs to see what failed and where.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl --json -l xerror '{device}'`
   Stop and use a lab: Stop for a lab if the log shows the same drive-side fault (IDNF, ABRT on identify) repeating.

2. Fast first pass that abandons a stalled area after a few minutes without progress.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -d -n -T 5m '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be imaged read-only into the named scratch image with a timed fast pass?
   Stop and use a lab: Stop for a lab if throughput stays near zero or the drive resets repeatedly.

3. Retry the unread areas on the same mapfile, one retry pass.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -d -r1 '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be read again, read-only, with one retry pass on the mapfile?
   Stop and use a lab: Stop for a lab if the retry pass still stalls on large areas.

4. Summarise the mapfile.
   Tool: `ddrescuelog` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescuelog -t '{map}'`
   Stop and use a lab: Stop for a lab if what is unread is data that matters.

5. Shorten the drive's own error recovery so reads fail fast instead of stalling (volatile setting).
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl -l scterc,70,70 '{device}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May SCT error recovery control be set to 7 seconds on this disk?
   Stop and use a lab: Stop for a lab if the drive does not support it and keeps stalling.

