#!/usr/bin/env bash
set -Eeuo pipefail

command -v npm >/dev/null 2>&1 || {
    echo "npm not found; run scripts/install-node-uv.sh first" >&2
    exit 1
}

PROFILE="${SHELL_PROFILE:-${HOME}/.bashrc}"
CODEX_PROXY_URL="${CODEX_PROXY_URL:-http://127.0.0.1:17890}"

npm i -g @openai/codex

touch "${PROFILE}"
if ! grep -Eq '^[[:space:]]*codexp[[:space:]]*\(\)[[:space:]]*\{' "${PROFILE}"; then
    cat >>"${PROFILE}" <<EOF_PROFILE

# Run Codex through the local reverse-SSH proxy only.
codexp() {
    HTTP_PROXY="${CODEX_PROXY_URL}" \\
    HTTPS_PROXY="${CODEX_PROXY_URL}" \\
    ALL_PROXY="${CODEX_PROXY_URL}" \\
    command codex "\$@"
}
EOF_PROFILE
fi

printf '\nCodex: %s\n' "$(codex --version)"
printf 'codexp proxy: %s\n' "${CODEX_PROXY_URL}"
printf '\nRun this once in the current terminal:\n  source %q\n' "${PROFILE}"
printf 'Then start Codex with:\n  codexp\n'
