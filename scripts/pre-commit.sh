#!/usr/bin/env bash
# The local half of the required check: the same two commands CI runs.
#
# Not a substitute for CI. A hook can be skipped and a worktree can be dirty in
# ways the pushed tree is not; branch protection on main is what actually blocks
# a merge. This exists so a broken suite is found in seconds rather than after a
# push. The three guard skills are model-driven and run neither here nor in CI
# (AGENTS.md section 5).
#
# Run by ~/.config/git/hooks/pre-commit, because core.hooksPath is set globally
# and .git/hooks is therefore never consulted.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# dash rather than sh: the module runs under KernelSU's busybox ash on the device,
# and the host's /bin/sh may be bash, which would accept a bashism the device
# rejects. CI installs dash for the same reason.
runner=dash
command -v dash >/dev/null 2>&1 || runner="sh"

"$runner" tests/test_generate_rules.sh

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning module/*.sh module/lib/*.sh tests/*.sh scripts/*.sh
else
    echo "pre-commit: shellcheck not installed; skipped. CI still runs it." >&2
fi
