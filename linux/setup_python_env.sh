#!/usr/bin/env bash
# Python 环境工具：普通用户安装选定组件，旧版本/偏好不自动变更。
# Linux；用法：bash setup_python_env.sh [--check] [uv|pyenv|poetry|pdm ...]
set -euo pipefail
if [[ $(id -u) == 0 ]]; then
    [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || { echo '请以普通用户运行' >&2; exit 2; }
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        exec sudo -H -u "$SUDO_USER" bash "${BASH_SOURCE[0]}" "$@"
    fi
    echo '请先下载脚本，再以普通用户运行；不在 root 下执行用户安装。' >&2
    exit 2
fi
export PATH="$HOME/.local/bin:$HOME/.pyenv/bin:$PATH"
if [[ "${1:-}" == --check ]]; then
    result=0
    for tool in uv pyenv poetry pdm; do
        if command -v "$tool" >/dev/null 2>&1; then "$tool" --version || result=1; else printf '%s: 未安装（可选）\n' "$tool"; fi
    done
    exit "$result"
fi
if [[ $# == 0 ]]; then
    read -r -p '安装组件 [uv/pyenv/poetry/pdm，以空格分隔，默认 uv]: ' selection
    read -r -a selected <<< "${selection:-uv}"
    set -- "${selected[@]}"
fi
for component in "$@"; do
    case "$component" in uv|pyenv|poetry|pdm) ;; *) echo "未知组件: $component" >&2; exit 2 ;; esac
done
command -v curl >/dev/null || { echo '需要 curl，请先通过包管理器安装。' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for component in "$@"; do
    if command -v "$component" >/dev/null 2>&1; then
        "$component" --version
        printf '%s 已安装，保留版本及配置。\n' "$component"
        continue
    fi
    case "$component" in
    uv)
        curl -fLsS --connect-timeout 10 --max-time 120 https://astral.sh/uv/0.10.0/install.sh -o "$work/uv.sh"
        UV_NO_MODIFY_PATH=1 sh "$work/uv.sh"
        ;;
    pyenv)
        [[ ! -e "$HOME/.pyenv" ]] || { echo '.pyenv 已存在但命令不可用；请先检查，不覆盖。' >&2; exit 1; }
        command -v git >/dev/null || { echo '需要 git' >&2; exit 1; }
        git clone --branch v2.6.3 --depth 1 https://github.com/pyenv/pyenv.git "$HOME/.pyenv"
        printf '%s\n' 'pyenv 已安装；编译 Python 所需系统依赖请按目标发行版安装。'
        ;;
    poetry)
        command -v python3 >/dev/null || { echo '需要 python3' >&2; exit 1; }
        curl -fLsS --connect-timeout 10 --max-time 120 https://install.python-poetry.org -o "$work/poetry.py"
        python3 "$work/poetry.py" --version 2.1.3
        ;;
    pdm)
        command -v python3 >/dev/null || { echo '需要 python3' >&2; exit 1; }
        curl -fLsS --connect-timeout 10 --max-time 120 https://raw.githubusercontent.com/pdm-project/pdm/2.25.9/install-pdm.py -o "$work/pdm.py"
        python3 "$work/pdm.py" --version 2.25.9
        ;;
    esac
    "$component" --version
 done
printf '%s\n' '选定组件验证完成。现有项目、默认 Python、keyring 和虚拟环境偏好保持原状。' '用户工具目录需在 PATH 中：~/.local/bin；pyenv 使用前需配置 shell init。'
