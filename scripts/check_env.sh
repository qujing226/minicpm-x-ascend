#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require_command cmake
require_command g++
require_command git
require_command npu-smi
require_command python3
load_cann_env

log "Platform"
printf 'architecture: %s\n' "$(uname -m)"
printf 'cmake:       %s\n' "$(cmake --version | head -n 1)"
printf 'g++:         %s\n' "$(g++ --version | head -n 1)"
printf 'CANN home:   %s\n' "${ASCEND_TOOLKIT_HOME}"

if [[ "$(uname -m)" != "aarch64" ]]; then
    printf 'WARNING: validated competition environment is aarch64\n' >&2
fi

[[ -d "${ASCEND_TOOLKIT_HOME}" ]] || die "invalid ASCEND_TOOLKIT_HOME: ${ASCEND_TOOLKIT_HOME}"
[[ -f "${ASCEND_TOOLKIT_HOME}/lib64/libascendcl.so" ]] || {
    die "libascendcl.so not found in ${ASCEND_TOOLKIT_HOME}/lib64"
}

log "ACL"
python3 -c 'import acl; print("SoC:", acl.get_soc_name())'

log "NPU"
npu-smi info

log "Environment check passed"
