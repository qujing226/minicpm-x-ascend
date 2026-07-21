#!/usr/bin/env bash
set -Eeuo pipefail

NODE_VERSION="${NODE_VERSION:-24.18.0}"
PYPI_INDEX="${PYPI_INDEX:-https://mirrors.aliyun.com/pypi/simple/}"
PROFILE="${SHELL_PROFILE:-${HOME}/.bashrc}"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf '\nERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "需要 root 或 sudo"
    SUDO="sudo"
fi

for command_name in curl tar python3; do
    command -v "${command_name}" >/dev/null 2>&1 || die "缺少命令: ${command_name}"
done

case "$(uname -m)" in
    aarch64|arm64) NODE_ARCH="arm64" ;;
    x86_64|amd64) NODE_ARCH="x64" ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
esac

NODE_FILE="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
NODE_DIR="/usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}"
NODE_BIN="${NODE_DIR}/bin"

if [[ "$(node --version 2>/dev/null || true)" == "v${NODE_VERSION}" ]] && command -v npm >/dev/null 2>&1; then
    log "复用 Node.js v${NODE_VERSION}"
else
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' EXIT

    log "下载 Node.js v${NODE_VERSION}"
    downloaded=0
    for url in \
        "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/${NODE_FILE}" \
        "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_FILE}"
    do
        printf '尝试: %s\n' "${url}"
        if curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
            "${url}" -o "${tmp_dir}/${NODE_FILE}"
        then
            downloaded=1
            break
        fi
    done
    (( downloaded == 1 )) || die "Node.js 下载失败"

    log "安装 Node.js"
    ${SUDO} mkdir -p /usr/local/lib/nodejs
    ${SUDO} rm -rf "${NODE_DIR}"
    ${SUDO} tar -xJf "${tmp_dir}/${NODE_FILE}" -C /usr/local/lib/nodejs
fi

# npm 全局安装的命令（包括 codex）会放在 Node 自身的 bin 目录中。
# 无论 Node 是新安装还是复用，都修复常用软链接，并让当前脚本立即可用。
for binary in node npm npx corepack; do
    if [[ -x "${NODE_BIN}/${binary}" ]]; then
        ${SUDO} ln -sfn "${NODE_BIN}/${binary}" "/usr/local/bin/${binary}"
    fi
done
export PATH="${NODE_BIN}:${HOME}/.local/bin:/usr/local/bin:${PATH}"

# Node 安装完成后立即配置 npm 国内 registry。
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
npm config set registry "${NPM_REGISTRY}"

log "安装 uv"
python -m pip install \
    --user \
    --upgrade \
    --index-url "${PYPI_INDEX}" \
    uv

mkdir -p "${HOME}/.local/bin"
touch "${PROFILE}"

add_line() {
    local line="$1"
    grep -Fqx "${line}" "${PROFILE}" 2>/dev/null || printf '\n%s\n' "${line}" >>"${PROFILE}"
}

add_line "export PATH=\"${NODE_BIN}:\$HOME/.local/bin:/usr/local/bin:\$PATH\""
add_line "export UV_DEFAULT_INDEX=\"${PYPI_INDEX}\""

export UV_DEFAULT_INDEX="${PYPI_INDEX}"

log "验证安装"
printf 'Node: %s (%s)\n' "$(node --version)" "$(command -v node)"
printf 'npm:  %s (%s)\n' "$(npm --version)" "$(npm config get registry)"
printf 'uv:   %s (%s)\n' "$(uv --version)" "$(command -v uv)"
printf '\nRun this once in the current terminal:\n  source %q\n' "${PROFILE}"
