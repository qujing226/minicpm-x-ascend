#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "scripts/common.sh must be sourced" >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-/workspace/llama.cpp-omni}"
BUILD_DIR="${BUILD_DIR:-${LLAMA_CPP_DIR}/build-cann91}"
MODEL_DIR="${MODEL_DIR:-${PROJECT_ROOT}/models/MiniCPM-o-4_5-gguf}"
MODEL_PATH="${MODEL_PATH:-${MODEL_DIR}/MiniCPM-o-4_5-F16.gguf}"

CANN_REQUIRED_RELEASE="${CANN_REQUIRED_RELEASE:-9.1.0-beta.1}"
CANN_REQUIRED_VERSION_PREFIX="${CANN_REQUIRED_VERSION_PREFIX:-9.1.0}"
CANN_DETECTED_VERSION=""
CANN_VERSION_FILE=""

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

detect_cann_version() {
    local candidate
    local version

    for candidate in \
        "${ASCEND_TOOLKIT_HOME:-}/opp/version.info" \
        "${ASCEND_TOOLKIT_HOME:-}/version.info" \
        /usr/local/Ascend/ascend-toolkit/latest/opp/version.info
    do
        [[ "${candidate}" != "/opp/version.info" ]] || continue
        [[ "${candidate}" != "/version.info" ]] || continue
        [[ -f "${candidate}" ]] || continue

        version="$(sed -n 's/^Version=//p' "${candidate}" | head -n 1)"
        if [[ -n "${version}" ]]; then
            CANN_DETECTED_VERSION="${version}"
            CANN_VERSION_FILE="${candidate}"
            return 0
        fi
    done

    return 1
}

require_cann_release() {
    detect_cann_version || {
        die "unable to detect CANN version from ASCEND_TOOLKIT_HOME=${ASCEND_TOOLKIT_HOME:-unset}"
    }

    if [[ "${CANN_DETECTED_VERSION}" != "${CANN_REQUIRED_VERSION_PREFIX}"* ]]; then
        die "CANN ${CANN_REQUIRED_RELEASE} is required; detected ${CANN_DETECTED_VERSION} via ${CANN_VERSION_FILE}"
    fi
}

load_cann_env() {
    if [[ -n "${ASCEND_TOOLKIT_HOME:-}" && -d "${ASCEND_TOOLKIT_HOME}" ]]; then
        require_cann_release
        return
    fi

    local candidate
    local candidates=()

    if [[ -n "${CANN_SET_ENV:-}" ]]; then
        candidates+=("${CANN_SET_ENV}")
    fi
    candidates+=(
        /usr/local/Ascend/cann-9.1.0-beta.1/set_env.sh
        /usr/local/Ascend/cann-9.1.0/set_env.sh
        /usr/local/Ascend/ascend-toolkit/9.1.0-beta.1/set_env.sh
        /usr/local/Ascend/ascend-toolkit/9.1.0/set_env.sh
        /usr/local/Ascend/ascend-toolkit/latest/set_env.sh
    )

    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}" ]]; then
            source "${candidate}"
            require_cann_release
            return
        fi
    done

    die "CANN ${CANN_REQUIRED_RELEASE} set_env.sh not found; set CANN_SET_ENV to the official image path"
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
