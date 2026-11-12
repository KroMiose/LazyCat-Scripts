#!/usr/bin/env bash
# Stage a verified native candidate without Python or implicit activation.
set -euo pipefail
version='';source_dir='';base_url='';bin_dir="${HOME:?}/.local/bin";activate=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--source-dir|--base-url|--bin-dir)
            [[ $# -ge 2 ]] || { echo '缺少参数值' >&2;exit 2; }
            case "$1" in --version) version="$2";; --source-dir) source_dir="$2";; --base-url) base_url="$2";; --bin-dir) bin_dir="$2";; esac
            shift 2 ;;
        --activate) activate=1;shift ;;
        --help) echo 'install-ssh.sh --version lazycat-ssh-vX.Y.Z [--source-dir DIR | --base-url HTTPS] [--bin-dir ABS] [--activate]';exit 0 ;;
        *) echo '未知参数' >&2;exit 2 ;;
    esac
done
[[ "$version" =~ ^lazycat-ssh-v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] || { echo '无效版本' >&2;exit 2; }
[[ -n "$source_dir" && -z "$base_url" || -z "$source_dir" && -n "$base_url" ]] || { echo '必须指定一个下载来源' >&2;exit 2; }
case "$(uname -s)" in Darwin) system=darwin;; Linux) system=linux;; *) echo '不支持的平台' >&2;exit 2;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64;; x86_64|amd64) arch=amd64;; *) echo '不支持的架构' >&2;exit 2;; esac
[[ "$bin_dir" == /* && "$bin_dir" != *[[:cntrl:]]* ]] || { echo '安装路径必须是绝对路径' >&2;exit 2; }
parent="$bin_dir"
while [[ -n "$parent" && "$parent" != / ]]; do
    if [[ -L "$parent" ]]; then
        case "$system:$parent" in darwin:/var|darwin:/tmp|darwin:/etc) ;; *) echo '安装路径包含待审阅的符号链接' >&2;exit 3;; esac
    fi
    parent="${parent%/*}"
done
mkdir -p "$bin_dir"
stage=$(mktemp -d "$bin_dir/.lazycat-candidate.XXXXXX")
trap 'rm -rf "$stage"' EXIT
fetch() {
    local name="$1" limit="$2" authority
    if [[ -n "$source_dir" ]]; then
        [[ -f "$source_dir/$name" && $(wc -c < "$source_dir/$name") -le "$limit" ]] || { echo '本地产物缺失或过大' >&2;return 1; }
        cp "$source_dir/$name" "$stage/$name"
    else
        [[ "$base_url" == https://* && "$base_url" != *[[:space:]]* && "$base_url" != *'?'* && "$base_url" != *'#'* ]] || { echo '需要不含查询或片段的 HTTPS 来源' >&2;return 2; }
        authority="${base_url#https://}";authority="${authority%%/*}"
        [[ -n "$authority" && "$authority" != *@* ]] || { echo '下载地址不得内嵌凭据' >&2;return 2; }
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 90 --max-filesize "$limit" "${base_url%/}/$name" -o "$stage/$name"
        [[ $(wc -c < "$stage/$name") -le "$limit" ]] || return 1
    fi
}
asset="$version-$system-$arch.tar.gz"
fetch SHA256SUMS 1048576
checksum=$(awk -v name="$asset" 'NF==2 && $2==name {n++;value=$1} END {if(n!=1) exit 1;print value}' "$stage/SHA256SUMS")
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo '校验清单缺失或重复' >&2;exit 1; }
fetch "$asset" 67108864
if command -v sha256sum >/dev/null; then actual=$(sha256sum "$stage/$asset");else actual=$(shasum -a 256 "$stage/$asset");fi
[[ "${actual%% *}" == "$checksum" ]] || { echo '产物校验失败' >&2;exit 1; }
[[ $(tar -tzf "$stage/$asset" | awk '$0=="lazycat-ssh" {n++} END {print n+0}') == 1 ]] || { echo '归档程序条目缺失或重复' >&2;exit 1; }
listing=$(tar -tvzf "$stage/$asset" lazycat-ssh)
[[ "$listing" == -* ]] || { echo '归档程序不是普通文件' >&2;exit 1; }
(ulimit -f 65536; tar -xOzf "$stage/$asset" lazycat-ssh > "$stage/lazycat-ssh")
chmod 755 "$stage/lazycat-ssh"
(ulimit -f 2048; exec "$stage/lazycat-ssh" version > "$stage/version.txt" 2> "$stage/version.err") &
version_pid=$!
deadline=$((SECONDS+10))
while kill -0 "$version_pid" 2>/dev/null; do
    if ((SECONDS>=deadline)); then
        kill -KILL "$version_pid" 2>/dev/null || true
        wait "$version_pid" 2>/dev/null || true
        echo '候选版本检查超时，未安装' >&2;exit 1
    fi
    sleep 0.1
done
wait "$version_pid" || { echo '候选版本检查失败，未安装' >&2;exit 1; }
[[ "$(cat "$stage/version.txt")" == "lazycat-ssh $version" ]] || { echo '候选版本不匹配' >&2;exit 1; }
# Exclusive hard link: never replace an existing command or candidate.
[[ ! -e "$bin_dir/lazycat-ssh-candidate" && ! -L "$bin_dir/lazycat-ssh-candidate" ]] || { echo '候选已存在，未覆盖' >&2;exit 3; }
ln "$stage/lazycat-ssh" "$bin_dir/lazycat-ssh-candidate"
printf '已暂存校验后的候选：%s\n' "$bin_dir/lazycat-ssh-candidate"
if [[ "$activate" == 1 ]]; then
    LAZYCAT_SSH_BIN_DIR="$bin_dir" "$bin_dir/lazycat-ssh-candidate" migrate --apply
else
    echo '现有程序和任务未切换；使用候选的 migrate --check 检查迁移条件。'
fi
