#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_command git

(( $# == 0 )) || die "usage: $0"
LLAMA_OMNI_REPO="https://github.com/tc-mb/llama.cpp-omni.git"

if [[ -f "${LLAMA_CPP_DIR}/CMakeLists.txt" && -d "${LLAMA_CPP_DIR}/.git" ]]; then
    log "Source already exists; preserving local state"
    printf 'path:   %s\n' "${LLAMA_CPP_DIR}"
    printf 'commit: %s\n' "$(git -C "${LLAMA_CPP_DIR}" log -1 --oneline)"
elif [[ -e "${LLAMA_CPP_DIR}" ]]; then
    die "${LLAMA_CPP_DIR} exists but is not a llama.cpp-omni Git checkout"
else
    mkdir -p "$(dirname -- "${LLAMA_CPP_DIR}")"
    log "Clone llama.cpp-omni"
    printf 'source: %s\n' "${LLAMA_OMNI_REPO}"
    printf 'target: %s\n' "${LLAMA_CPP_DIR}"
    git clone --depth 1 "${LLAMA_OMNI_REPO}" "${LLAMA_CPP_DIR}"
fi

require_command cmake
require_command g++
require_command npu-smi
load_cann_env

BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
SHELL_PROFILE="${SHELL_PROFILE:-${HOME}/.bashrc}"

log "Build configuration"
printf 'source:       %s\n' "${LLAMA_CPP_DIR}"
printf 'build:        %s\n' "${BUILD_DIR}"
printf 'CANN home:    %s\n' "${ASCEND_TOOLKIT_HOME}"
printf 'parallelism:  %s\n' "${BUILD_JOBS}"
printf 'commit:       %s\n' "$(git -C "${LLAMA_CPP_DIR}" rev-parse --short HEAD)"

if [[ -n "$(git -C "${LLAMA_CPP_DIR}" status --short)" ]]; then
    printf 'WARNING: source tree has local changes; they are preserved.\n' >&2
fi

cmake \
    -S "${LLAMA_CPP_DIR}" \
    -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CANN=ON \
    -DLLAMA_OPENSSL=OFF

cmake \
    --build "${BUILD_DIR}" \
    --config Release \
    -j "${BUILD_JOBS}" \
    --target llama-omni-server llama-omni-cli

[[ -x "${LLAMA_SERVER_BIN}" ]] || die "missing build artifact: ${LLAMA_SERVER_BIN}"
[[ -x "${LLAMA_CLI_BIN}" ]] || die "missing build artifact: ${LLAMA_CLI_BIN}"

export PATH="${BUILD_DIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${BUILD_DIR}/bin${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

log "CANN linkage"
for binary in "${LLAMA_SERVER_BIN}" "${LLAMA_CLI_BIN}"; do
    ldd "${binary}" | grep -q 'libggml-cann' || {
        die "$(basename -- "${binary}") is not linked with GGML CANN"
    }
done

log "Write llama.cpp-omni commands to ${SHELL_PROFILE}"
touch "${SHELL_PROFILE}"
tmp_profile="$(mktemp)"
trap 'rm -f "${tmp_profile}"' EXIT

awk '
    $0 == "# >>> llama.cpp-omni >>>" { skip = 1; next }
    $0 == "# <<< llama.cpp-omni <<<" { skip = 0; next }
    /\.config\/llama\.cpp-omni\/env\.sh/ { next }
    !skip { print }
' "${SHELL_PROFILE}" >"${tmp_profile}"

cat >>"${tmp_profile}" <<EOF_PROFILE

# >>> llama.cpp-omni >>>
case ":\${PATH}:" in
    *":${BUILD_DIR}/bin:"*) ;;
    *) export PATH="${BUILD_DIR}/bin:\${PATH}" ;;
esac
case ":\${LD_LIBRARY_PATH:-}:" in
    *":${BUILD_DIR}/bin:"*) ;;
    *) export LD_LIBRARY_PATH="${BUILD_DIR}/bin\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}" ;;
esac
# <<< llama.cpp-omni <<<
EOF_PROFILE

cat "${tmp_profile}" >"${SHELL_PROFILE}"
rm -f "${tmp_profile}"
trap - EXIT

require_command llama-omni-server
require_command llama-omni-cli

log "Build completed"
ls -lh "${LLAMA_SERVER_BIN}" "${LLAMA_CLI_BIN}"
printf 'server command: %s\n' "$(command -v llama-omni-server)"
printf 'CLI command:    %s\n' "$(command -v llama-omni-cli)"
printf '\nRun this once in the current terminal:\n  source %q\n' "${SHELL_PROFILE}"
