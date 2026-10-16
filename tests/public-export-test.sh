#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Targeted test for tests/public-export.sh and tests/link-check.py: exports
# this checkout into a scratch directory, checks what is and is not in it,
# plants development-process traces in copies and sees each one found, and
# checks the refusals. Unprivileged; boots nothing. The scratch directory is
# under ~/.cache/system-rescuer/ (override with PUBLIC_EXPORT_TEST_DIR).
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
base=${PUBLIC_EXPORT_TEST_DIR:-$HOME/.cache/system-rescuer/public-export-test}
mkdir -p -- "$base"
scratch=$(mktemp -d -- "$base/run.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
failed=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }
cond() { # <name> <test command...>: ok if the command succeeds
    local name=$1
    shift
    if "$@"; then ok "$name"; else bad "$name"; fi
}
check() { # <name> <exit status wanted: 0|1> <command...>
    local name=$1 want=$2 got
    shift 2
    "$@" >"$scratch/out" 2>&1
    got=$?
    if { [[ $want == 0 ]] && (( got == 0 )); } || { [[ $want == 1 ]] && (( got != 0 )); }; then
        ok "$name"
    else
        bad "$name (exit $got)"
        sed 's/^/     /' "$scratch/out" | head -10
    fi
}

# Scratch patterns: planning-file entries for the excluded names. The owner's
# private patterns are not read here.
patterns=$scratch/patterns
printf 'planning-file\t^(AGENTS|CLAUDE|ROADMAP)\\.md$\nplanning-file\t^(\\.claude|\\.codex|knowledge)(/|$)\nplanning-file\t^docs/(roadmap[^/]*|idea-brief\\.md|features\\.md|research\\.md|(proposals|bugs|claims|decisions)/.*)$\nplanning-file\t^research-manifest\\.json$\n' > "$patterns"

export_dir=$scratch/export
check "export succeeds" 0 "$here/tests/public-export.sh" "$export_dir"

absent=1
for p in AGENTS.md CLAUDE.md ROADMAP.md research-manifest.json knowledge .claude .codex .githooks/pre-push public \
    docs/features.md docs/research.md docs/decisions docs/proposals docs/bugs; do
    [[ -e $export_dir/$p || -L $export_dir/$p ]] && { bad "excluded path $p is in the export"; absent=0; }
done
(( absent )) && ok "no excluded path is in the export"
cond "the threat model is in the export" test -f "$export_dir/docs/threat-model.md"
cond "the quickstart is in the export" test -f "$export_dir/docs/quickstart.md"
cond "the README's demo is in the export" test -f "$export_dir/docs/demo.mp4" -a -f "$export_dir/docs/demo-poster.png"
cond "the agent brief is in the export" test -f "$export_dir/profile/airootfs/root/rescue/AGENTS.md"
cond "the public ci workflow is in the export" test -f "$export_dir/.github/workflows/ci.yml"
cond "the public security workflow is in the export" test -f "$export_dir/.github/workflows/security.yml"
cond "exported public-paths has no public/" test -z "$(grep '^public/' "$export_dir/tests/public-paths")"
cond "exported public-paths names the workflows" grep -q '^\.github/workflows/$' "$export_dir/tests/public-paths"
# Every path the exported list names exists in the export.
missing=0
while IFS= read -r p; do
    [[ -e $export_dir/${p%/} ]] || { bad "exported public-paths names $p, absent"; missing=1; }
done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$export_dir/tests/public-paths")
(( missing )) || ok "every exported public-paths entry exists"

# Hosted runners only, with the fork guard on every job, and no pinned action
# other than the two we allow.
wf=$export_dir/.github/workflows
cond "workflows name no self-hosted runner or ubuntu-latest" bash -c '! grep -Eq "self-hosted|ubuntu-latest|runs-on: \[" "$@"' _ "$wf"/*.yml
cond "every job runs on ubuntu-24.04" test "$(grep -c 'runs-on: ubuntu-24.04$' "$wf"/ci.yml)" = 1

bad_uses=$(grep -h 'uses:' "$wf"/*.yml | grep -Ev 'uses: (actions/checkout|gitleaks/gitleaks-action)@[0-9a-f]{40} ' || true)
cond "workflows use only pinned checkout and gitleaks" test -z "$bad_uses"
check "workflow check passes on the export" 0 "$here/tests/workflow-check.sh" --dir "$wf"

check "leak check with dev-process finds nothing" 0 \
    "$here/tests/leak-check.sh" --dev-process --denylist /dev/null --patterns "$patterns" --tree "$export_dir"
check "link check passes" 0 python3 -I "$here/tests/link-check.py" "$export_dir"

# plant <name> <command...>: run the command in a fresh copy of the export,
# then expect the leak check to find something there.
plant_leak() {
    local name=$1 copy=$scratch/plant
    shift
    rm -rf -- "$copy"
    cp -a -- "$export_dir" "$copy"
    ( cd -- "$copy" && "$@" ) >/dev/null 2>&1
    check "planted $name is found" 1 \
        "$here/tests/leak-check.sh" --dev-process --denylist /dev/null --patterns "$patterns" --tree "$copy"
}
# Assembled at run time so this file holds no planning id itself.
phase_ref="Pha""se 12"
todo_ref="TODO(Pha""se 12)"
plant_leak "phase reference" bash -c "echo '# see $phase_ref' >> build.sh"
plant_leak "phase-named TODO" bash -c "echo '# $todo_ref' >> lib/rescue-stick.sh"
plant_leak "ROADMAP.md" touch ROADMAP.md
plant_leak ".claude directory" bash -c "mkdir .claude && echo {} > .claude/settings.json"

# A planted link to ROADMAP.md fails the link check.
rm -rf -- "$scratch/plant"
cp -a -- "$export_dir" "$scratch/plant"
echo '[plan](ROADMAP.md)' >> "$scratch/plant/README.md"
check "a link to ROADMAP.md fails the link check" 1 python3 -I "$here/tests/link-check.py" "$scratch/plant"
rm -rf -- "$scratch/plant"
cp -a -- "$export_dir" "$scratch/plant"
echo '![shot](docs/missing.png)' >> "$scratch/plant/SECURITY.md"
check "a missing image fails the link check" 1 python3 -I "$here/tests/link-check.py" "$scratch/plant"
rm -rf -- "$scratch/plant"

# Refusals.
check "a non-empty target is refused" 1 "$here/tests/public-export.sh" "$export_dir"
check "a target inside the repository is refused" 1 "$here/tests/public-export.sh" "$here/out/public-export-test-target"
[[ -e $here/out/public-export-test-target ]] && { bad "refused target was created"; rmdir "$here/out/public-export-test-target" 2>/dev/null; }

exit "$failed"
