#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

missing=0
log "Checking model set in ${MODEL_DIR}"

while IFS= read -r relative_path; do
    path="${MODEL_DIR}/${relative_path}"
    if [[ ! -s "${path}" ]]; then
        printf 'MISSING  %s\n' "${relative_path}" >&2
        missing=1
    else
        size="$(stat -c '%s' "${path}")"
        printf 'OK       %-58s %s bytes\n' "${relative_path}" "${size}"
    fi
done < <(required_model_files)

incomplete_files=()
while IFS= read -r path; do
    incomplete_files+=("${path}")
done < <(find "${MODEL_DIR}" -type f -name '*.incomplete' 2>/dev/null | sort)

if (( ${#incomplete_files[@]} > 0 )); then
    printf '\nIncomplete downloads detected:\n' >&2
    printf '  %s\n' "${incomplete_files[@]}" >&2
    missing=1
fi

if (( missing != 0 )); then
    die "model set is incomplete; run: cd ${PROJECT_ROOT} && uv run download_model.py"
fi

log "All competition-required GGUF files are present"
