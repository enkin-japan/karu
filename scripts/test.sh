#!/bin/bash
# Full test run with a bounded Swift Testing parallelism width.
# Why: with unlimited width a dozen CPU-bound tests occupy every thread-pool
# thread, and the GCD global queue, the cooperative pool and Task.sleep
# wake-ups then stall for seconds, which times out wall-clock waits.
# SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH is experimental and may stop
# working after a toolchain upgrade. Override with KARU_TEST_WIDTH=<n>, or set
# the variable yourself. All arguments pass through to `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="${SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH:-${KARU_TEST_WIDTH:-8}}"
exec swift test "$@"
