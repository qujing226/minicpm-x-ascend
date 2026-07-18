#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_command npu-smi
load_cann_env

command -v llama-omni-cli >/dev/null 2>&1 || {
    die "llama-omni-cli not found in PATH; run build_llama_omni.sh and source ~/.bashrc"
}

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-600}"
SMOKE_TEST_COUNT="${SMOKE_TEST_COUNT:-1}"
AUDIO_TEST_PREFIX="${AUDIO_TEST_PREFIX:-${LLAMA_CPP_DIR}/tools/omni/assets/test_case/audio_test_case/audio_test_case_}"
started_pid=""

[[ "${SMOKE_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || die "SMOKE_TIMEOUT must be a positive integer"
[[ "${SMOKE_TEST_COUNT}" =~ ^[1-9][0-9]*$ ]] || die "SMOKE_TEST_COUNT must be a positive integer"

cleanup() {
    local pid="${started_pid}"
    [[ -n "${pid}" ]] || return 0

    trap - EXIT INT TERM
    kill "${pid}" 2>/dev/null || true

    local _
    for _ in $(seq 1 20); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}" 2>/dev/null || true
    fi
    wait "${pid}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "Preflight"
"${SCRIPT_DIR}/check_models.sh"
cli_path="$(command -v llama-omni-cli)"
printf 'CLI:          %s\n' "${cli_path}"
printf 'model:        %s\n' "${MODEL_PATH}"
printf 'audio prefix: %s\n' "${AUDIO_TEST_PREFIX}"
printf 'test count:   %s\n' "${SMOKE_TEST_COUNT}"

ldd "${cli_path}" | grep -q 'libggml-cann' || {
    die "llama-omni-cli is not linked with GGML CANN"
}

for ((i = 0; i < SMOKE_TEST_COUNT; i++)); do
    printf -v index '%04d' "${i}"
    [[ -s "${AUDIO_TEST_PREFIX}${index}.wav" ]] || {
        die "missing smoke audio: ${AUDIO_TEST_PREFIX}${index}.wav"
    }
done

log "Run llama-omni-cli smoke inference"
cli_args=(
    -m "${MODEL_PATH}"
    -c "${CTX_SIZE}"
    -ngl "${N_GPU_LAYERS}"
    --no-tts
    --test "${AUDIO_TEST_PREFIX}" "${SMOKE_TEST_COUNT}"
)
(
    cd "${LLAMA_CPP_DIR}"
    exec llama-omni-cli "${cli_args[@]}"
) &
started_pid=$!

seen_on_npu=0
deadline=$((SECONDS + SMOKE_TIMEOUT))
while kill -0 "${started_pid}" 2>/dev/null; do
    npu_info="$(npu-smi info 2>/dev/null || true)"
    if grep -Eq "(^|[[:space:]])${started_pid}([[:space:]]|$)" <<<"${npu_info}"; then
        seen_on_npu=1
    fi

    if (( SECONDS >= deadline )); then
        die "llama-omni-cli exceeded SMOKE_TIMEOUT=${SMOKE_TIMEOUT}s"
    fi
    sleep 1
done

exit_code=0
wait "${started_pid}" || exit_code=$?
started_pid=""

if (( exit_code != 0 )); then
    die "llama-omni-cli failed with exit code ${exit_code}"
fi

(( seen_on_npu == 1 )) || {
    die "llama-omni-cli completed but was never visible in npu-smi"
}

log "CLI smoke test passed"
