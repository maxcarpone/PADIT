#!/usr/bin/env bash
# PADIT - Server dependency modernization regression suite.
# Historical modernization lots M01-M10.
# See Appendix A in WAPT_CHECKPOINT.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${1:-${REPO_ROOT}/build/python2-runtime-server-bookworm/bin/python}"

if [ ! -x "${PYTHON}" ]; then
    echo "ERROR: Python runtime not executable: ${PYTHON}" >&2
    exit 1
fi

echo "=== PADIT SERVER DEPENDENCY REGRESSION SUITE ==="
echo "Runtime: ${PYTHON}"

for number in 01 02 03 04 05 06 07 08 09 10; do
    test_script="${REPO_ROOT}/utils/test-server-dependencies-m${number}.py"

    if [ ! -f "${test_script}" ]; then
        echo "ERROR: Missing M${number} test: ${test_script}" >&2
        exit 1
    fi

    echo
    echo ">>> Testing PADIT modernization M${number}"

    PYTHONPATH="${REPO_ROOT}${PYTHONPATH:+:${PYTHONPATH}}" \
        "${PYTHON}" "${test_script}"

    echo "PADIT M${number}: PASS"
done

echo
echo "PADIT SERVER DEPENDENCIES M01-M10: PASS"
