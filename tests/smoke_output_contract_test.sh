#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_LOG="$(mktemp /tmp/minicpm-smoke-contract.XXXXXX.log)"
trap 'rm -f "${RUN_LOG}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    printf '%s\n' '--- smoke output ---' >&2
    cat "${RUN_LOG}" >&2
    exit 1
}

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}" \
    bash "${REPO_ROOT}/scripts/smoke_test.sh" >"${RUN_LOG}" 2>&1 || {
        fail "smoke_test.sh returned a non-zero exit code"
    }

grep -Fq 'test count:   2' "${RUN_LOG}" || {
    fail "the default smoke test did not include reference audio plus user audio"
}

grep -Fq 'stream_prefill(index=1): processing user audio:' "${RUN_LOG}" || {
    fail "the user-audio prefill path was not exercised"
}

awk '
    /^=== Assistant Response ===$/ { in_response = 1; next }
    /^=== End Assistant Response ===$/ { in_response = 0; saw_end = 1; next }
    in_response && $0 ~ /[^[:space:]]/ { saw_text = 1 }
    END { exit !(saw_end && saw_text) }
' "${RUN_LOG}" || {
    fail "the CLI did not print a non-empty assistant response"
}

PERSISTED_LOG="$(sed -n 's/^Smoke log: *//p' "${RUN_LOG}" | tail -n 1)"
[[ -n "${PERSISTED_LOG}" && -s "${PERSISTED_LOG}" ]] || {
    fail "the smoke test did not persist its full output log"
}

printf 'PASS: smoke output contract\n'
