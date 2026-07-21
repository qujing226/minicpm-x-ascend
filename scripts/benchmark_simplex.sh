#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

require_command npu-smi
require_command python3
load_cann_env

BENCH_WARMUP="${BENCH_WARMUP:-1}"
BENCH_RUNS="${BENCH_RUNS:-5}"
BENCH_TIMEOUT="${BENCH_TIMEOUT:-600}"
BENCH_SAMPLE_INTERVAL="${BENCH_SAMPLE_INTERVAL:-0.2}"
BENCH_SEED="${BENCH_SEED:-42}"
BENCH_N_PREDICT="${BENCH_N_PREDICT:-128}"
AUDIO_TEST_PREFIX="${AUDIO_TEST_PREFIX:-${LLAMA_CPP_DIR}/tools/omni/assets/test_case/audio_test_case/audio_test_case_}"
BENCH_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BENCH_RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)_$$"
BENCH_OUTPUT_DIR="${BENCH_OUTPUT_DIR:-${STATE_DIR}/benchmark/${BENCH_RUN_STAMP}}"
PARSER="${SCRIPT_DIR}/parse_simplex_benchmark.py"
RESULTS_JSONL="${BENCH_OUTPUT_DIR}/results.jsonl"
SUMMARY_JSON="${BENCH_OUTPUT_DIR}/summary.json"
WARMUP_JSONL="${BENCH_OUTPUT_DIR}/warmup.jsonl"

active_cli_pid=""
active_sampler_pid=""

[[ "${BENCH_WARMUP}" =~ ^[0-9]+$ ]] || die "BENCH_WARMUP must be a non-negative integer"
[[ "${BENCH_RUNS}" =~ ^[1-9][0-9]*$ ]] || die "BENCH_RUNS must be a positive integer"
[[ "${BENCH_N_PREDICT}" =~ ^[1-9][0-9]*$ ]] || die "BENCH_N_PREDICT must be a positive integer"
[[ "${BENCH_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || die "BENCH_TIMEOUT must be a positive integer"
[[ "${BENCH_SEED}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || die "BENCH_SEED must be an integer from 0 to 4294967294"
if ((BENCH_SEED > 4294967294)); then
    die "BENCH_SEED must be an integer from 0 to 4294967294"
fi
[[ "${BENCH_SAMPLE_INTERVAL}" =~ ^(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*(\.[0-9]+)?)$ ]] || {
    die "BENCH_SAMPLE_INTERVAL must be a positive number"
}

stop_process() {
    local pid="$1"
    local attempt
    [[ -n "${pid}" ]] || return 0
    if ! kill -0 "${pid}" 2>/dev/null; then
        wait "${pid}" 2>/dev/null || true
        return 0
    fi

    kill "${pid}" 2>/dev/null || true
    for ((attempt = 0; attempt < 20; attempt++)); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}" 2>/dev/null || true
    fi
    wait "${pid}" 2>/dev/null || true
}

cleanup() {
    trap - EXIT INT TERM
    stop_process "${active_sampler_pid}"
    stop_process "${active_cli_pid}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git_revision() {
    local repository="$1"
    local revision
    revision="$(git -C "${repository}" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
    if [[ -n "$(git -C "${repository}" status --porcelain 2>/dev/null)" ]]; then
        revision="${revision}-dirty"
    fi
    printf '%s\n' "${revision}"
}

capture_npu_sample() {
    local phase="$1"
    local output_file="$2"
    printf '=== NPU SAMPLE epoch_ms=%s phase=%s ===\n' \
        "$(date +%s%3N)" "${phase}" >>"${output_file}"
    npu-smi info >>"${output_file}" 2>&1 || {
        printf 'npu-smi info failed with exit code %s\n' "$?" >>"${output_file}"
    }
}

sample_npu_until_exit() {
    local cli_pid="$1"
    local output_file="$2"
    while kill -0 "${cli_pid}" 2>/dev/null; do
        capture_npu_sample runtime "${output_file}"
        sleep "${BENCH_SAMPLE_INTERVAL}"
    done
}

run_once() {
    local label="$1"
    local run_id="$2"
    local output_jsonl="$3"
    local cli_log="${BENCH_OUTPUT_DIR}/${label}.cli.log"
    local npu_log="${BENCH_OUTPUT_DIR}/${label}.npu.log"
    local cli_pid
    local exit_code=0
    local start_epoch_ms
    local end_epoch_ms
    local process_elapsed_ms
    local deadline
    local timed_out=0

    : >"${cli_log}"
    : >"${npu_log}"
    capture_npu_sample baseline "${npu_log}"

    start_epoch_ms="$(date +%s%3N)"
    (
        cd "${LLAMA_CPP_DIR}"
        exec "${CLI_PATH}" \
            -m "${MODEL_PATH}" \
            -c "${CTX_SIZE}" \
            -ngl "${N_GPU_LAYERS}" \
            --seed "${BENCH_SEED}" \
            --n-predict "${BENCH_N_PREDICT}" \
            --no-tts \
            --test "${AUDIO_TEST_PREFIX}" 2
    ) >"${cli_log}" 2>&1 &
    cli_pid=$!
    active_cli_pid="${cli_pid}"

    sample_npu_until_exit "${cli_pid}" "${npu_log}" &
    active_sampler_pid=$!

    deadline=$((SECONDS + BENCH_TIMEOUT))
    while kill -0 "${cli_pid}" 2>/dev/null; do
        if ((SECONDS >= deadline)); then
            timed_out=1
            stop_process "${cli_pid}"
            break
        fi
        sleep 0.1
    done

    if ((timed_out == 1)); then
        exit_code=124
    else
        wait "${cli_pid}" || exit_code=$?
    fi
    active_cli_pid=""
    end_epoch_ms="$(date +%s%3N)"
    process_elapsed_ms=$((end_epoch_ms - start_epoch_ms))

    stop_process "${active_sampler_pid}"
    active_sampler_pid=""

    python3 "${PARSER}" run \
        --cli-log "${cli_log}" \
        --npu-log "${npu_log}" \
        --run-id "${run_id}" \
        --exit-code "${exit_code}" \
        --process-id "${cli_pid}" \
        --process-elapsed-ms "${process_elapsed_ms}" \
        --output "${output_jsonl}"
}

log "Simplex benchmark preflight"
"${SCRIPT_DIR}/check_models.sh"

CLI_PATH="${LLAMA_CLI_BIN}"
if [[ ! -x "${CLI_PATH}" ]]; then
    CLI_PATH="$(command -v llama-omni-cli || true)"
fi
[[ -n "${CLI_PATH}" && -x "${CLI_PATH}" ]] || {
    die "llama-omni-cli not found; run build_llama_omni.sh"
}
[[ -f "${PARSER}" ]] || die "benchmark parser not found: ${PARSER}"
ldd "${CLI_PATH}" | grep -q 'libggml-cann' || {
    die "llama-omni-cli is not linked with GGML CANN"
}

for index in 0000 0001; do
    [[ -s "${AUDIO_TEST_PREFIX}${index}.wav" ]] || {
        die "missing benchmark audio: ${AUDIO_TEST_PREFIX}${index}.wav"
    }
done

mkdir -p "${BENCH_OUTPUT_DIR}"
: >"${RESULTS_JSONL}"
: >"${WARMUP_JSONL}"

PROJECT_COMMIT="$(git_revision "${PROJECT_ROOT}")"
LLAMA_COMMIT="$(git_revision "${LLAMA_CPP_DIR}")"

printf 'output dir:      %s\n' "${BENCH_OUTPUT_DIR}"
printf 'CLI:             %s\n' "${CLI_PATH}"
printf 'CANN:            %s (target %s)\n' "${CANN_DETECTED_VERSION}" "${CANN_REQUIRED_RELEASE}"
printf 'model:           %s\n' "${MODEL_PATH}"
printf 'audio input:     %s0001.wav\n' "${AUDIO_TEST_PREFIX}"
printf 'warmup runs:     %s\n' "${BENCH_WARMUP}"
printf 'measured runs:   %s\n' "${BENCH_RUNS}"
printf 'sample interval: %ss\n' "${BENCH_SAMPLE_INTERVAL}"
printf 'sampler seed:    %s\n' "${BENCH_SEED}"
printf 'max output:      %s token steps\n' "${BENCH_N_PREDICT}"

for ((run_id = 1; run_id <= BENCH_WARMUP; run_id++)); do
    printf '\nWarmup %d/%d\n' "${run_id}" "${BENCH_WARMUP}"
    printf -v label 'warmup_%03d' "${run_id}"
    run_once "${label}" "${run_id}" "${WARMUP_JSONL}" || {
        die "warmup ${run_id} failed; inspect ${BENCH_OUTPUT_DIR}/${label}.cli.log"
    }
done

measured_failures=0
for ((run_id = 1; run_id <= BENCH_RUNS; run_id++)); do
    printf '\nMeasured run %d/%d\n' "${run_id}" "${BENCH_RUNS}"
    printf -v label 'run_%03d' "${run_id}"
    if ! run_once "${label}" "${run_id}" "${RESULTS_JSONL}"; then
        measured_failures=$((measured_failures + 1))
    fi
done

summary_exit=0
python3 "${PARSER}" summary \
    --results "${RESULTS_JSONL}" \
    --output "${SUMMARY_JSON}" \
    --started-at-utc "${BENCH_STARTED_AT}" \
    --warmup-runs "${BENCH_WARMUP}" \
    --measured-runs "${BENCH_RUNS}" \
    --sample-interval-seconds "${BENCH_SAMPLE_INTERVAL}" \
    --seed "${BENCH_SEED}" \
    --n-predict "${BENCH_N_PREDICT}" \
    --model-path "${MODEL_PATH}" \
    --audio-prefix "${AUDIO_TEST_PREFIX}" \
    --cli-path "${CLI_PATH}" \
    --project-commit "${PROJECT_COMMIT}" \
    --llama-commit "${LLAMA_COMMIT}" || summary_exit=$?

printf 'results JSONL:   %s\n' "${RESULTS_JSONL}"
printf 'summary JSON:   %s\n' "${SUMMARY_JSON}"

if ((measured_failures > 0 || summary_exit != 0)); then
    die "benchmark completed with ${measured_failures} failed measured run(s)"
fi

log "Simplex benchmark passed"
