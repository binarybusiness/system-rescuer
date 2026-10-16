#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Targeted test for tests/workflow-check.sh: this repository's workflows pass;
# planted workflows that let a fork reach a self-hosted runner fail and are
# named; a hosted job without the guard passes; a missing directory, an
# unparsable file and a directory without workflow files exit 2.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
check="$here/workflow-check.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
failed=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
# named FILE JOB: the findings in $out name that file and job.
named() { awk -F'\t' -v f="$1" -v j="$2" '$1 == f && $2 == j { found = 1 } END { exit !found }' <<< "$out"; }

mkdir -p "$scratch/unsafe" "$scratch/safe" "$scratch/hosted" "$scratch/bad" "$scratch/empty"

cat > "$scratch/unsafe/unguarded.yml" <<'EOF'
name: Unguarded
on:
  push:
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - run: echo build
EOF
cat > "$scratch/unsafe/weakened.yml" <<'EOF'
name: Weakened
on:
  pull_request:
jobs:
  build:
    if: github.event_name != 'pull_request'
    runs-on: [self-hosted, linux]
    steps:
      - run: echo build
EOF
cat > "$scratch/unsafe/pr-target.yml" <<'EOF'
name: Target
on:
  pull_request_target:
jobs:
  verify:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, linux]
    steps:
      - run: echo verify
EOF
cat > "$scratch/unsafe/expr.yml" <<'EOF'
name: Expression
on: push
jobs:
  matrix-job:
    runs-on: ${{ matrix.runner }}
    steps:
      - run: echo matrix
EOF
cat > "$scratch/unsafe/labels.yml" <<'EOF'
name: Labels
on:
  pull_request:
jobs:
  build:
    runs-on:
      labels: [self-hosted, linux]
    steps:
      - run: echo build
EOF
cat > "$scratch/unsafe/reusable.yml" <<'EOF'
name: Reusable
on:
  pull_request:
jobs:
  call:
    uses: ./.github/workflows/shared.yml
EOF
cat > "$scratch/unsafe/hosted.yml" <<'EOF'
name: Hosted
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
EOF
cat > "$scratch/safe/good.yml" <<'EOF'
name: Good
on:
  push:
  pull_request:
jobs:
  verify:
    if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}
    runs-on: [self-hosted, linux, x64]
    steps:
      - run: echo verify
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
  call:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    uses: ./.github/workflows/shared.yml
EOF
cat > "$scratch/hosted/hosted.yml" <<'EOF'
name: Hosted only
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
EOF
cat > "$scratch/unsafe/target-call.yml" <<'EOF'
name: Target call
on:
  pull_request_target:
jobs:
  call:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    uses: ./.github/workflows/shared.yml
EOF
printf 'name: Broken\njobs: [\n' > "$scratch/bad/broken.yml"
mkdir -p "$scratch/repeated"
cat > "$scratch/repeated/repeated.yml" <<'EOF'
name: Repeated
on:
  pull_request:
jobs:
  build:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    runs-on: [self-hosted, linux]
    steps:
      - run: echo build
EOF

out=$("$check" 2>"$scratch/err"); rc=$?
if (( rc == 0 )) && [[ -z $out ]] && grep -q ', 0 findings$' "$scratch/err"; then
    pass "this repository's workflows pass: $(cat "$scratch/err")"
else
    fail "this repository's workflows: exit $rc, output: $out, stderr: $(cat "$scratch/err")"
fi

out=$("$check" --dir "$scratch/safe" 2>"$scratch/err"); rc=$?
if (( rc == 0 )) && [[ -z $out ]]; then
    pass "guarded self-hosted jobs, a hosted job and a guarded call pass"
else
    fail "safe workflow: exit $rc, output: $out"
fi

out=$("$check" --dir "$scratch/hosted" 2>"$scratch/err"); rc=$?
if (( rc == 0 )) && [[ -z $out ]]; then
    pass "a hosted job without the guard passes"
else
    fail "hosted-only workflow: exit $rc, output: $out"
fi

out=$("$check" --dir "$scratch/unsafe" 2>"$scratch/err"); rc=$?
if (( rc == 1 )) && named unguarded.yml build && named weakened.yml build \
    && named pr-target.yml verify && named expr.yml matrix-job \
    && named labels.yml build && named reusable.yml call \
    && named target-call.yml call; then
    pass "each planted unsafe job is named"
else
    fail "planted unsafe workflows: exit $rc, output: $out"
fi

if named hosted.yml lint; then
    fail "a hosted job without the guard was reported"
else
    pass "a hosted job without the guard is not reported"
fi

out=$("$check" --dir "$scratch/none" 2>"$scratch/err"); rc=$?
if (( rc == 2 )); then pass "a missing directory is an error"; else fail "missing directory: exit $rc"; fi

out=$("$check" --dir "$scratch/bad" 2>"$scratch/err"); rc=$?
if (( rc == 2 )) && grep -q 'broken.yml' "$scratch/err"; then
    pass "an unparsable file is an error and is named"
else
    fail "unparsable file: exit $rc, stderr: $(cat "$scratch/err")"
fi

out=$("$check" --dir "$scratch/repeated" 2>"$scratch/err"); rc=$?
if (( rc == 2 )) && grep -q 'repeated.yml' "$scratch/err"; then
    pass "a repeated key, which could hide a job's runner, is an error and is named"
else
    fail "repeated key: exit $rc, stderr: $(cat "$scratch/err")"
fi

out=$("$check" --dir "$scratch/empty" 2>"$scratch/err"); rc=$?
if (( rc == 2 )); then pass "a directory without workflow files is an error"; else fail "empty directory: exit $rc"; fi

out=$("$check" --bogus 2>"$scratch/err"); rc=$?
if (( rc == 2 )); then pass "an unknown option is a usage error"; else fail "unknown option: exit $rc"; fi

(( failed == 0 )) && echo "workflow-check-test: all assertions passed"
exit "$failed"
