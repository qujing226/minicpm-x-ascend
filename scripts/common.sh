#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "scripts/common.sh must be sourced" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/workspace/llama.cpp-omni}"
BUILD_DIR="${BUILD_DIR:-${LLAMA_CPP_DIR}/build}"
MODEL_DIR="${MODEL_DIR:-${PROJECT_ROOT}/models/MiniCPM-o-4_5-gguf}"
MODEL_PATH="${MODEL_PATH:-${MODEL_DIR}/MiniCPM-o-4_5-F16.gguf}"

CTX_SIZE="${CTX_SIZE:-4096}"
N_GPU_LAYERS="${N_GPU_LAYERS:-99}"

STATE_DIR="${STATE_DIR:-${PROJECT_ROOT}/var}"
LOG_DIR="${LOG_DIR:-${STATE_DIR}/log}"
OUTPUT_DIR="${OUTPUT_DIR:-${STATE_DIR}/output}"

LLAMA_SERVER_BIN="${BUILD_DIR}/bin/llama-omni-server"
LLAMA_CLI_BIN="${BUILD_DIR}/bin/llama-omni-cli"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_state_dirs() {
    mkdir -p "${LOG_DIR}" "${OUTPUT_DIR}"
}

load_cann_env() {
    if [[ -n "${ASCEND_TOOLKIT_HOME:-}" && -d "${ASCEND_TOOLKIT_HOME}" ]]; then
        return
    fi

    local candidate
    for candidate in \
        /usr/local/Ascend/cann/set_env.sh \
        /usr/local/Ascend/ascend-toolkit/set_env.sh \
        /usr/local/Ascend/ascend-toolkit/latest/set_env.sh \
        /usr/local/Ascend/cann-*/set_env.sh
    do
        if [[ -f "${candidate}" ]]; then
            source "${candidate}"
            return
        fi
    done

    die "CANN set_env.sh not found under /usr/local/Ascend"
}

required_model_files() {
    printf '%s\n' \
        "MiniCPM-o-4_5-F16.gguf" \
        "audio/MiniCPM-o-4_5-audio-F16.gguf" \
        "vision/MiniCPM-o-4_5-vision-F16.gguf" \
        "tts/MiniCPM-o-4_5-tts-F16.gguf" \
        "tts/MiniCPM-o-4_5-projector-F16.gguf" \
        "token2wav-gguf/encoder.gguf" \
        "token2wav-gguf/flow_matching.gguf" \
        "token2wav-gguf/flow_extra.gguf" \
        "token2wav-gguf/hifigan2.gguf" \
        "token2wav-gguf/prompt_cache.gguf"
}
