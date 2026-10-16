#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Targeted test for tests/spdx-check.sh: a scratch tree with licensed source
# files passes; a planted script without the line, by shebang alone or by
# name, fails and is named; a document and a copied disk playbook are not
# source and pass without one.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check="$here/spdx-check.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
failed=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

tag="SPDX-License-""Identifier: GPL-3.0-or-later"
holder='SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)'
mkdir -p "$scratch/tree/bin" "$scratch/tree/lib" "$scratch/tree/profile/airootfs/root/diskrepair-playbooks"
printf '#!/usr/bin/env bash\n# %s\n# %s\necho ok\n' "$tag" "$holder" > "$scratch/tree/bin/good"
printf '# %s\n# %s\nx = 1\n' "$tag" "$holder" > "$scratch/tree/lib/good.py"
printf '// %s\n// %s\nexport {}\n' "$tag" "$holder" > "$scratch/tree/lib/good.js"
printf '# Notes\nNo licence line, not source.\n' > "$scratch/tree/README.md"
printf '#!/bin/sh\necho copied\n' > "$scratch/tree/profile/airootfs/root/diskrepair-playbooks/copied.sh"
printf 'bin/\nlib/\nREADME.md\nprofile/\n' > "$scratch/paths"

if out=$("$check" --tree "$scratch/tree" --paths "$scratch/paths" 2>/dev/null) && [[ -z $out ]]; then
    pass "a licensed tree passes"
else
    fail "a licensed tree fails: $out"
fi

mkdir -p "$scratch/tree/profile/airootfs/usr/local/bin"
printf '#!/bin/bash\n# %s\necho upstream\n' "$tag" > "$scratch/tree/profile/airootfs/usr/local/bin/choose-mirror"
if "$check" --tree "$scratch/tree" --paths "$scratch/paths" > /dev/null 2>&1; then
    pass "copied upstream source retains its own notices without our holder"
else
    fail "copied upstream source was wrongly claimed"
fi
printf '# %s\nx = 1\n' "$tag" > "$scratch/tree/lib/no-holder.py"
printf '# %s\n# SPDX-FileCopyrightText: 2026 Someone Else\nx = 1\n' "$tag" > "$scratch/tree/lib/wrong-holder.py"
printf '# %s\n\n\n\n\n# %s\nx = 1\n' "$tag" "$holder" > "$scratch/tree/lib/late-holder.py"
printf '#!/bin/bash\n# %s\necho ours\n' "$tag" > "$scratch/tree/profile/airootfs/usr/local/bin/rescue-new"
out=$("$check" --tree "$scratch/tree" --paths "$scratch/paths" 2>/dev/null); rc=$?
expected=$(printf 'missing-copyright\tlib/late-holder.py\nmissing-copyright\tlib/no-holder.py\nmissing-copyright\tlib/wrong-holder.py\nmissing-copyright\tprofile/airootfs/usr/local/bin/rescue-new')
if (( rc == 1 )) && [[ $out == "$expected" ]]; then
    pass "missing, wrong and late holders fail; an owned neighbor is not exempt"
else
    fail "holder refusals: exit $rc, output: $out"
fi
rm -- "$scratch/tree/lib/no-holder.py" "$scratch/tree/lib/wrong-holder.py" "$scratch/tree/lib/late-holder.py" "$scratch/tree/profile/airootfs/usr/local/bin/rescue-new"

printf '#!/usr/bin/env python3\nprint(1)\n' > "$scratch/tree/bin/planted"
printf 'echo no shebang\n' > "$scratch/tree/lib/planted.sh"
out=$("$check" --tree "$scratch/tree" --paths "$scratch/paths" 2>/dev/null); rc=$?
expected=$(printf 'missing\tbin/planted\nmissing-copyright\tbin/planted\nmissing\tlib/planted.sh\nmissing-copyright\tlib/planted.sh')
if (( rc == 1 )) && [[ $out == "$expected" ]]; then
    pass "planted files without the line fail and are named"
else
    fail "planted files: exit $rc, output: $out"
fi

"$check" --tree "$scratch/tree" --paths "$scratch/nonexistent" > /dev/null 2>&1; rc=$?
if (( rc == 2 )); then pass "a missing paths file is a usage error"; else fail "missing paths file: exit $rc"; fi

(( failed == 0 )) && echo "spdx-check-test: all assertions passed"
exit "$failed"
