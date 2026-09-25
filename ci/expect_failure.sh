#!/usr/bin/env bash
#
# Run a command that MUST fail, and must fail for the stated reason.
#
#   ci/expect_failure.sh "<expected substring>" <command> [args...]
#
# An inverted exit code alone is not enough for most of the gates in this package. Several of the
# negative tests run on duckdb, where the AI wrappers cannot succeed anyway, so a non-zero exit
# proves nothing about which check fired. Matching the message is what separates "the spend gate
# stopped us" from "duckdb has no embed implementation".
#
# Prints the full captured output on failure so a CI log shows what actually happened.

set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <expected substring> <command> [args...]" >&2
    exit 2
fi

expected="$1"
shift

output="$("$@" 2>&1)"
status=$?

if [ "$status" -eq 0 ]; then
    printf '%s\n' "$output"
    echo "::error::expected a non-zero exit, but the command succeeded: $*"
    exit 1
fi

if ! printf '%s' "$output" | grep -qF -- "$expected"; then
    printf '%s\n' "$output"
    echo "::error::command failed (exit $status) but not with the expected message"
    echo "::error::expected to find: $expected"
    exit 1
fi

echo "failed as expected: $expected"
