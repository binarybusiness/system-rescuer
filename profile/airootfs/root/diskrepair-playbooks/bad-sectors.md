# HDD growing bad sectors

Slug: `bad-sectors`

## Triage

- From `inspect`: reallocated, pending, offline-uncorrectable or reported-uncorrectable counts above zero, rising between two inspect runs, mean the surface is degrading; every extra read and every power-on can lose more.
- Image first, in this order: one fast pass that skips the damaged areas and scrapes nothing (`-n`), then bounded retries (`-r`) on the same mapfile. Never start with retries or scraping on a growing count.
- No self-test, sector remap or destructive surface test before the image is complete; each is an owner decision on that disk, is not run from the rescue stick, and none recovers data.
- A repaired or remapped sector holds zeros or a vendor pattern, not the old data: only the image keeps what was readable.

## Inspect selection

Uses `inspect disks[].verdict` and `disks[].reasons`: mode health-reasons; verdict in failing, watch; a reason contains one of 'reallocated', 'pending', 'offline uncorrectable', 'reallocation events', 'reported uncorrectable'; priority 20 when several playbooks match.

## Register cases

- `7Y250P0_Y6423ZDE`

## Steps

1. Read the health data again and compare the counts with the earlier inspect run.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl --json -x '{device}'`
   Stop and use a lab: Stop for a lab if the counts grew by hundreds between runs, or the drive clicks, resets or drops off the bus.

2. Fast first pass: copy every easily readable sector, skip bad areas, no scraping.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -d -n '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be imaged read-only into the named scratch image with a ddrescue fast pass (-n)?
   Stop and use a lab: Stop for a lab if the drive clicks, stops responding, or most of the first pass fails.

3. Retry the bad areas on the same mapfile with a bounded number of retries.
   Tool: `GNU ddrescue` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescue -f -d -r3 '{device}' '{image}' '{map}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May this disk be read again, read-only, with up to three retry passes on the mapfile?
   Stop and use a lab: Stop for a lab if retries make no progress or the remaining unread area is data that matters.

4. Summarise the mapfile: how much is rescued and how much is still bad.
   Tool: `ddrescuelog` — catalog: GNU ddrescue; route pacman:ddrescue; writes: yes
   Command: `ddrescuelog -t '{map}'`
   Stop and use a lab: Stop for a lab if the unread part covers the filesystem metadata or the files that matter.

5. Only after imaging and with the owner's decision, run an extended self-test to confirm the surface state.
   Tool: `smartctl` — catalog: smartctl; route pacman:smartmontools; writes: yes
   Command: `smartctl -t long '{device}'`
   OWNER DECISION REQUIRED:
   Ask the owner: May an extended self-test run on this disk now that its image is complete?
   Stop and use a lab: Stop for a lab if the self-test aborts on a read failure and the drive keeps resetting.

6. Remap one confirmed unreadable sector so the drive stops stalling on it (destroys that sector's content).
   Not on the rescue stick — owner-attended workstation only

7. Destructive surface test of the whole disk, only for a disk the owner has decided to reuse.
   Not on the rescue stick — owner-attended workstation only

