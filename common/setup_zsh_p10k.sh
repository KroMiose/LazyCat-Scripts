#!/bin/bash

# ==============================================================================
# 脚本名称: setup_zsh_p10k.sh
# 功    能: 自动化安装 Zsh, Oh My Zsh, 并可选安装 Powerlevel10k 主题
#           以及 zsh-autosuggestions 和 zsh-syntax-highlighting 插件。
#           它会自动处理 git, curl, zsh 的依赖安装。
# 适用系统: 主流 Linux (Debian/Ubuntu, RHEL/CentOS, Arch) & macOS
# 仓库入口: bash common/setup_zsh_p10k.sh；安装与兼容说明见 common/README.md。
# ==============================================================================

set -euo pipefail

# lazycat-file-transaction:begin
# Single-file candidate/backup protocol. Embedded into standalone release scripts.
# Call lc_tx_begin, edit "$LC_TX_CANDIDATE", validate, then lc_tx_commit.
lc_tx_copy() {
    # GNU cp -p preserves modes/ACLs but silently drops user xattrs. Request
    # xattr explicitly (rather than --preserve=all, which tolerates failures).
    case "$(uname -s)" in
        Linux) cp --preserve=mode,ownership,timestamps,xattr -- "$1" "$2" ;;
        Darwin) cp -p "$1" "$2" ;;
        *) echo '未验证的文件属性复制平台，未提交修改' >&2; return 1 ;;
    esac
}
# inode plus nanosecond ctime detects metadata-only edits (including ACL/xattr)
# without adding Python/getfattr as an installation dependency.
lc_tx_revision() {
    case "$(uname -s)" in
        Linux) LC_ALL=C stat -c '%d:%i:%z' -- "$1" ;;
        Darwin) LC_ALL=C stat -f '%d:%i:%Fc' "$1" ;;
        *) return 1 ;;
    esac
}
# Automatic failure recovery may only replace the exact revision we published.
# Missing revision evidence is a conflict, not permission to discard user attrs.
lc_tx_matches_committed() {
    local target="$1" operation="$2"
    [[ -f "$target" && ! -L "$target" && -f "$operation/after" && ! -L "$operation/after" &&
       -f "$operation/committed-revision" && ! -L "$operation/committed-revision" ]] || return 3
    [[ "$(lc_tx_revision "$target")" == "$(cat "$operation/committed-revision")" ]] &&
        cmp -s "$target" "$operation/after" || return 3
}
lc_tx_check_revision() {
    lc_tx_check_path "$LC_TX_TARGET" || return 3
    if [[ "$LC_TX_EXISTED" == 1 ]]; then
        [[ -f "$LC_TX_TARGET" && "$(lc_tx_revision "$LC_TX_TARGET")" == "$LC_TX_REVISION" ]] || { echo '文件或属性被并发修改，已停止' >&2; return 3; }
    else
        [[ ! -e "$LC_TX_TARGET" && ! -L "$LC_TX_TARGET" ]] || { echo '目标被并发创建，已停止' >&2; return 3; }
    fi
}
lc_tx_check_path() {
    local parent="$1"
    while [[ -n "$parent" && "$parent" != / ]]; do
        if [[ -L "$parent" ]]; then
            case "$parent" in
                /var|/tmp|/etc) [[ "$(uname -s)" == Darwin && "$parent" != "$1" ]] || { echo '路径包含符号链接，需要先明确采纳' >&2; return 3; } ;;
                *) echo '路径包含符号链接，需要先明确采纳' >&2; return 3 ;;
            esac
        fi
        parent="${parent%/*}"
    done
}
lc_tx_begin() {
    LC_TX_TARGET="$1"
    [[ "$LC_TX_TARGET" == /* && "$LC_TX_TARGET" != *$'\n'* && "$LC_TX_TARGET" != *$'\r'* ]] || { echo '事务目标必须是绝对单行路径' >&2; return 2; }
    lc_tx_check_path "$LC_TX_TARGET" || return 3
    LC_TX_LOCK="${LC_TX_TARGET}.lazycat-lock"
    LC_TX_LOCK_OWNED=0
    [[ ! -e "${LC_TX_LOCK}.recovery" && ! -L "${LC_TX_LOCK}.recovery" ]] || { echo '锁恢复正在进行或中断，请检查恢复记录' >&2; return 3; }
    (umask 077; mkdir "$LC_TX_LOCK") || { echo "操作锁已存在，请检查并发或中断状态：$LC_TX_LOCK" >&2; return 3; }
    LC_TX_LOCK_OWNED=1
    # Bash $$ identifies the original shell even inside a live subshell.
    # exec makes the helper's parent the actual caller, including Bash 3.2.
    LC_TX_OWNER_PID=$(exec /bin/sh -c 'printf "%s\n" "$PPID"')
    [[ "$LC_TX_OWNER_PID" =~ ^[1-9][0-9]*$ ]] || return 3
    printf '%s\n' "$LC_TX_OWNER_PID" > "$LC_TX_LOCK/pid"
    printf 'actual-shell-v1\n' > "$LC_TX_LOCK/pid-format"
    if [[ -e "${LC_TX_LOCK}.recovery" || -L "${LC_TX_LOCK}.recovery" ]]; then lc_tx_unlock; echo '锁恢复与新操作冲突，未写入目标' >&2; return 3; fi
    LC_TX_OPERATION=$(mktemp -d "${LC_TX_TARGET}.lazycat-operation.XXXXXX")
    chmod 700 "$LC_TX_OPERATION"
    printf '%s\n' "$LC_TX_TARGET" > "$LC_TX_OPERATION/target"
    LC_TX_EXISTED=0
    if [[ -e "$LC_TX_TARGET" ]]; then
        [[ -f "$LC_TX_TARGET" ]] || { lc_tx_unlock; echo '目标不是普通文件' >&2; return 3; }
        LC_TX_EXISTED=1
        LC_TX_REVISION=$(lc_tx_revision "$LC_TX_TARGET") || { lc_tx_unlock; return 1; }
        LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_TARGET" | awk '{print $1, $3, $4}')
        printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
        lc_tx_copy "$LC_TX_TARGET" "$LC_TX_OPERATION/before" || { lc_tx_unlock; return 1; }
    else
        (umask 077; : > "$LC_TX_OPERATION/before")
    fi
    lc_tx_check_revision || { lc_tx_unlock; return 3; }
    LC_TX_METADATA=$(LC_ALL=C ls -ldn "$LC_TX_OPERATION/before" | awk '{print $1, $3, $4}')
    printf '%s\n' "$LC_TX_METADATA" > "$LC_TX_OPERATION/metadata"
    printf '%s\n' "$LC_TX_EXISTED" > "$LC_TX_OPERATION/existed"
    lc_tx_copy "$LC_TX_OPERATION/before" "$LC_TX_OPERATION/after" || { lc_tx_unlock; return 1; }
    LC_TX_CANDIDATE="$LC_TX_OPERATION/after"
    printf 'prepared\n' > "$LC_TX_OPERATION/status"
}
# Explicit stale-lock recovery. A live/reused PID, incomplete lock or competing
# recovery is a conflict. Keep the original lock as evidence; never delete it.
lc_tx_recover_lock() (
    set -e
    local target="$1" lock guard pid archived process result
    [[ "$target" == /* && "$target" != *$'\n'* && "$target" != *$'\r'* ]] || return 2
    lc_tx_check_path "$target" || return 3
    lock="${target}.lazycat-lock"
    guard="${lock}.recovery"
    [[ -d "$lock" && ! -L "$lock" && -f "$lock/pid" && ! -L "$lock/pid" ]] || { echo '锁缺失、损坏或为链接，需人工检查' >&2; return 3; }
    [[ -f "$lock/pid-format" && ! -L "$lock/pid-format" && "$(cat "$lock/pid-format")" == actual-shell-v1 ]] || { echo '旧锁没有实际持锁进程证据，需人工检查，未移动' >&2; return 3; }
    (umask 077; mkdir "$guard") || return 3
    trap 'rmdir "$guard"' EXIT
    IFS= read -r pid < "$lock/pid"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo '锁的 PID 无效，未移动' >&2; return 3; }
    # ps also sees processes which kill -0 cannot probe due to permissions.
    result=0
    process=$(LC_ALL=C ps -p "$pid" -o pid=) || result=$?
    [[ "$result" == 1 && -z "$process" ]] || { echo '锁的进程仍存在或无法确认，未移动' >&2; return 3; }
    archived=$(mktemp -d "${lock}.recovered.XXXXXX")
    chmod 700 "$archived"
    mv "$lock" "$archived/lock"
    printf '已保存失效锁：%s\n目标与事务备份未修改；请检查后回滚或重新执行。\n' "$archived"
)
lc_tx_unlock() {
    [[ -n "${LC_TX_LOCK:-}" && "${LC_TX_LOCK_OWNED:-0}" == 1 ]] || return 0
    [[ ! -L "$LC_TX_LOCK" && -f "$LC_TX_LOCK/pid" && ! -L "$LC_TX_LOCK/pid" &&
       "$(cat "$LC_TX_LOCK/pid")" == "${LC_TX_OWNER_PID:-}" &&
       "$(exec /bin/sh -c 'printf "%s\n" "$PPID"')" == "${LC_TX_OWNER_PID:-}" ]] || { echo '锁归属变化，未释放' >&2; return 3; }
    rm -f "$LC_TX_LOCK/pid" "$LC_TX_LOCK/pid-format"
    rmdir "$LC_TX_LOCK"
    LC_TX_LOCK=''
    LC_TX_LOCK_OWNED=0
}
lc_tx_commit() {
    lc_tx_check_revision || return 3
    if [[ "$LC_TX_EXISTED" == 1 ]]; then
        [[ "$(LC_ALL=C ls -ldn "$LC_TX_TARGET" | awk '{print $1, $3, $4}')" == "$LC_TX_METADATA" ]] || { echo '文件权限或属主被并发修改' >&2; return 3; }
        cmp -s "$LC_TX_TARGET" "$LC_TX_OPERATION/before" || { echo '检测到并发修改，已停止' >&2; return 3; }
    else
        [[ ! -e "$LC_TX_TARGET" ]] || { echo '目标被并发创建，已停止' >&2; return 3; }
    fi
    if [[ "$LC_TX_EXISTED" == 1 && "$(LC_ALL=C ls -ldn "$LC_TX_CANDIDATE" | awk '{print $1, $3, $4}')" == "$LC_TX_METADATA" ]] && cmp -s "$LC_TX_CANDIDATE" "$LC_TX_OPERATION/before"; then
        rm -rf "$LC_TX_OPERATION"
        lc_tx_unlock
        return 0
    fi
    local staged
    staged=$(mktemp "${LC_TX_TARGET}.lazycat-stage.XXXXXX")
    lc_tx_copy "$LC_TX_CANDIDATE" "$staged" || { rm -f "$staged"; return 1; }
    lc_tx_check_revision || { rm -f "$staged"; return 3; }
    if ! mv "$staged" "$LC_TX_TARGET"; then rm -f "$staged"; return 1; fi
    # A later metadata-only edit must also prevent destructive rollback. Record
    # the published inode, not the candidate inode which rename may replace.
    lc_tx_revision "$LC_TX_TARGET" > "$LC_TX_OPERATION/committed-revision" || return 1
    printf 'committed\n' > "$LC_TX_OPERATION/status"
    lc_tx_unlock
    printf '操作记录与备份：%s\n' "$LC_TX_OPERATION"
}
lc_remove_block_candidate() {
    local file="$1" begin="$2" end="$3" tmp
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { if (inside || seen++) bad=1; inside=1 }
        $0 == end { if (!inside) bad=1; inside=0 }
        END { exit (bad || inside) ? 1 : 0 }
    ' "$file" || { echo '托管标记损坏，未修改目标文件' >&2; return 3; }
    tmp=$(mktemp "${file}.XXXXXX")
    lc_tx_copy "$file" "$tmp" || { rm -f "$tmp"; return 1; }
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { inside=1; next }
        $0 == end { inside=0; next }
        !inside { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}
# lazycat-file-transaction:end

MODE="install"
ASSUME_YES=0
CLEAN_REMOVE_INSTALLED_COMPONENTS=0
CLEAN_REMOVE_LEGACY_LINES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup)
            MODE="cleanup"
            shift
            ;;
        --cleanup-all)
            MODE="cleanup"
            CLEAN_REMOVE_INSTALLED_COMPONENTS=1
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        *)
            echo "❌ 未知参数: $1" >&2
            echo "用法:" >&2
            echo "  - 安装:   $0" >&2
            echo "  - 清理:   $0 --cleanup" >&2
            echo "  - 清理+卸载: $0 --cleanup-all" >&2
            echo "  - 非交互: $0 -y" >&2
            exit 1
            ;;
    esac
done

# Function to check for and install missing dependencies
ensure_dependencies() {
    local required_cmds=("git" "curl" "zsh")
    local missing_cmds=()
    local cmd
    echo "🔎 正在检查所需依赖..."
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo "⚠️  检测到以下依赖项缺失: ${missing_cmds[*]}"
        
        local pkg_manager=""
        local install_cmd=""

        if [[ "$(uname)" == "Darwin" ]]; then
            if ! command -v brew >/dev/null 2>&1; then
                echo "❌ 错误: Homebrew 未安装。请先从 https://brew.sh/ 安装。" >&2
                exit 1
            fi
            pkg_manager="Homebrew"
            install_cmd="brew install ${missing_cmds[*]}"
        elif command -v apt-get >/dev/null 2>&1; then
            pkg_manager="apt"
            install_cmd="sudo apt-get update && sudo apt-get install -y ${missing_cmds[*]}"
        elif command -v dnf >/dev/null 2>&1; then
            pkg_manager="dnf"
            install_cmd="sudo dnf install -y ${missing_cmds[*]}"
        elif command -v yum >/dev/null 2>&1; then
            pkg_manager="yum"
            install_cmd="sudo yum install -y ${missing_cmds[*]}"
        elif command -v pacman >/dev/null 2>&1; then
            pkg_manager="pacman"
            install_cmd="sudo pacman -S --noconfirm --needed ${missing_cmds[*]}"
        else
            echo "❌ 无法检测到支持的包管理器 (apt, dnf, yum, pacman, brew)。" >&2
            echo "   请您手动安装缺失的依赖后，再重新运行此脚本。" >&2
            exit 1
        fi

        if [[ "$ASSUME_YES" -eq 1 ]]; then confirm_install=Y; else
        read -p "脚本可以尝试使用 '${pkg_manager}' 为您安装。此操作可能需要 sudo 权限。是否继续？ (Y/n): " confirm_install
        confirm_install=${confirm_install:-Y}
        fi

        if [[ "$confirm_install" =~ ^[Yy]$ ]]; then
            echo "⏳ 正在运行安装命令..."
            eval "$install_cmd"
            
            for cmd in "${missing_cmds[@]}"; do
                if ! command -v "$cmd" >/dev/null 2>&1; then
                    echo "❌ 错误: '$cmd' 安装失败。请您手动安装后再试。" >&2
                    exit 1
                fi
            done
            echo "✅ 所有依赖均已成功安装。"
        else
            echo "🛑 用户取消了安装。请您手动安装依赖。"
            exit 1
        fi
    else
        echo "✅ 所有依赖项均已安装。"
    fi
}

remove_lazycat_managed_block() {
    local zshrc_file="$1"
    local start_marker="# --- LAZYCAT-SCRIPTS ZSH MANAGED START ---"
    local end_marker="# --- LAZYCAT-SCRIPTS ZSH MANAGED END ---"

    [[ ! -L "$zshrc_file" ]] || { echo '拒绝替换符号链接' >&2; return 1; }
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { if (inside || seen++) exit 1; inside=1 }
        $0 == end { if (!inside) exit 1; inside=0 }
        END { if (inside) exit 1 }
    ' "$zshrc_file" || { echo '托管标记损坏，原文件未修改' >&2; return 1; }
    if ! grep -qFx -- "$start_marker" "$zshrc_file"; then return 0; fi

    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    lc_tx_copy "$zshrc_file" "$tmp_file"
    awk -v start="$start_marker" -v end="$end_marker" '
        $0 == start { in_block=1; next }
        $0 == end { in_block=0; next }
        !in_block { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}

sanitize_zshrc_known_bad_lines() {
    local zshrc_file="$1"
    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    lc_tx_copy "$zshrc_file" "$tmp_file"

    # 历史版本脚本错误地把 `p10k configure` 写进 .zshrc，导致 zsh 启动时直接报错并中断主题/插件加载。
    awk '
        $0 == "# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh." { next }
        $0 == "[[ ! -f ~/.p10k.zsh ]] && p10k configure" { next }
        # 历史版本脚本误用单引号 echo '\nZSH_THEME=...'，导致字面量 \n 写入文件。
        $0 ~ /^\\nZSH_THEME=/ { sub(/^\\n/, "", $0); }
        { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}

zshrc_has_omz_source() {
    local zshrc_file="$1"
    # 匹配常见写法：
    # - source $ZSH/oh-my-zsh.sh
    # - . $ZSH/oh-my-zsh.sh
    # - source ~/.oh-my-zsh/oh-my-zsh.sh
    grep -qE '^[[:space:]]*(source|\.)[[:space:]]+"?(\$ZSH|~\/\.oh-my-zsh|\$HOME\/\.oh-my-zsh)"?\/oh-my-zsh\.sh"?([[:space:]]|$)' "$zshrc_file"
}

inject_lazycat_block_before_omz_source() {
    local zshrc_file="$1"
    local block_file="$2"
    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    lc_tx_copy "$zshrc_file" "$tmp_file"

    awk -v block_path="$block_file" '
        BEGIN {
            while ((getline line < block_path) > 0) {
                block = block line "\n"
            }
            close(block_path)
        }
        !inserted && $0 ~ /^[[:space:]]*(source|\.)[[:space:]]+"?(\$ZSH|~\/\.oh-my-zsh|\$HOME\/\.oh-my-zsh)"?\/oh-my-zsh\.sh"?([[:space:]]|$)/ {
            printf "%s", block
            inserted=1
        }
        { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}

append_lazycat_block() {
    local zshrc_file="$1"
    local block_file="$2"
    {
        if [[ -s "$zshrc_file" && -n "$(tail -n 1 "$zshrc_file")" ]]; then echo ""; fi
        cat "$block_file"
    } >> "$zshrc_file"
}

remove_legacy_theme_and_plugin_lines() {
    local zshrc_file="$1"
    local tmp_file
    tmp_file="$(mktemp "${zshrc_file}.tmp.XXXXXX")"
    lc_tx_copy "$zshrc_file" "$tmp_file"

    awk '
        # 仅清理历史版本脚本常见注入行（非托管块）。避免误删用户自定义内容。
        $0 == "ZSH_THEME=\"powerlevel10k/powerlevel10k\"" { next }
        $0 ~ /^plugins=\(/ && $0 ~ /zsh-autosuggestions/ && $0 ~ /zsh-syntax-highlighting/ { next }
        { print }
    ' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
}


# Work only on a same-directory candidate. Unknown user edits win over commits.
begin_zshrc_edit() {
    ZSHRC_TARGET="$HOME/.zshrc"
    [[ ! -e "$HOME/.lazycat-zsh.lock" && ! -L "$HOME/.lazycat-zsh.lock" ]] || {
        echo '旧 Zsh 操作锁仍存在，请先审阅；未删除旧锁或备份。' >&2
        return 3
    }
    trap lc_tx_unlock EXIT
    lc_tx_begin "$ZSHRC_TARGET"
    ZSHRC_FILE="$LC_TX_CANDIDATE"
}
commit_zshrc_edit() {
    zsh -n "$ZSHRC_FILE"
    lc_tx_commit
}

# --- 安全检查 ---
if [ "$(id -u)" -eq 0 ]; then
    echo "❌ 错误: 请不要使用 'sudo' 来运行此脚本。" >&2
    echo "   本脚本旨在配置当前用户的环境，只会在需要时请求 sudo 权限。" >&2
    exit 1
fi

# --- 依赖处理 ---
if [[ "$MODE" == "install" ]]; then
    if [[ -e "$HOME/.oh-my-zsh" || -L "$HOME/.oh-my-zsh" ]]; then
        [[ -d "$HOME/.oh-my-zsh" && -s "$HOME/.oh-my-zsh/oh-my-zsh.sh" && -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || {
            echo 'Oh My Zsh 目录存在但加载文件缺失或为空；请先修复，不覆盖现有组件或修改 Shell 配置。' >&2
            exit 1
        }
    fi
    ensure_dependencies
fi

if [[ "$MODE" == "cleanup" ]]; then
    ZSHRC_FILE="$HOME/.zshrc"
    echo "🧹 正在清理 Zsh 配置 (由 LazyCat-Scripts 写入的内容)..."

    [[ -e "$ZSHRC_FILE" ]] || exit 0
    begin_zshrc_edit
    remove_lazycat_managed_block "$ZSHRC_FILE"
    commit_zshrc_edit
    if [[ "$CLEAN_REMOVE_INSTALLED_COMPONENTS" -eq 1 ]]; then
        echo '组件目录没有可验证的安装归属记录，已保留；--cleanup-all 仅移除托管配置。'
    fi

    echo "✅ 清理完成。你现在可以重新运行本脚本进行安装。"
    exit 0
fi

# --- 交互式选项 ---
echo ""
echo "--- Zsh 环境配置选项 ---"
if [[ "$ASSUME_YES" -eq 1 ]]; then
    confirm_p10k="Y"
else
    read -p "是否要安装 Powerlevel10k 主题？ (Y/n): " confirm_p10k
fi
confirm_p10k=${confirm_p10k:-Y} # 默认为 Yes

if [[ "$ASSUME_YES" -eq 1 ]]; then
    confirm_plugins="Y"
else
    read -p "是否要安装 zsh-autosuggestions (自动补全) 和 zsh-syntax-highlighting (语法高亮) 插件？ (Y/n): " confirm_plugins
fi
confirm_plugins=${confirm_plugins:-Y} # 默认为 Yes
echo ""


# --- 安装 Oh My Zsh ---
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "⏳ 正在安装 Oh My Zsh..."
    # 使用 sh -c 来非交互式地运行安装脚本
    # RUNZSH=no: 安装后不立即启动 zsh
    # CHSH=no: 不自动修改默认 shell (因为我们已要求用户手动设置)
    omz_installer=$(mktemp)
    if ! curl -fSL --connect-timeout 15 --max-time 120 https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$omz_installer"; then
        rm -f "$omz_installer"; exit 1
    fi
    RUNZSH=no CHSH=no sh "$omz_installer" --unattended --keep-zshrc
    rm -f "$omz_installer"
else
    echo "✅ Oh My Zsh 已经安装。"
fi
[[ -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" && -s "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || {
    echo 'Oh My Zsh 安装器未生成有效加载文件；安装未完成，未写入 Shell 配置。' >&2
    exit 1
}

# 定义 Zsh 插件和主题的自定义目录
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"

# --- 根据选择安装组件 ---
if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    if [ ! -d "${ZSH_CUSTOM}/themes/powerlevel10k" ]; then
        echo "⏳ 正在安装 Powerlevel10k 主题..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "${ZSH_CUSTOM}/themes/powerlevel10k"
    else
        echo "✅ Powerlevel10k 主题已经安装。"
    fi
fi

if [[ "$confirm_plugins" =~ ^[Yy]$ ]]; then
    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-autosuggestions" ]; then
        echo "⏳ 正在安装 zsh-autosuggestions 插件 (自动补全)..."
        git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM}/plugins/zsh-autosuggestions"
    else
        echo "✅ zsh-autosuggestions 插件已经安装。"
    fi

    if [ ! -d "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting" ]; then
        echo "⏳ 正在安装 zsh-syntax-highlighting 插件 (语法高亮)..."
        git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting"
    else
        echo "✅ zsh-syntax-highlighting 插件已经安装。"
    fi
fi

# --- 配置 .zshrc ---
ZSHRC_FILE="$HOME/.zshrc"
echo "🔧 正在配置 .zshrc 文件..."

begin_zshrc_edit
remove_lazycat_managed_block "$ZSHRC_FILE"

echo "  -> 正在写入托管配置块 (幂等)..."
PLUGINS_LIST=("git")
if [[ "$confirm_plugins" =~ ^[Yy]$ ]]; then
    PLUGINS_LIST+=("zsh-autosuggestions" "zsh-syntax-highlighting")
fi

# --- 关键修复：确保 Oh My Zsh 会被加载，并在其之前注入正确的 p10k 配置加载逻辑 ---
LAZYCAT_BLOCK_FILE="$(mktemp)"
{
    echo "# --- LAZYCAT-SCRIPTS ZSH MANAGED START ---"
    echo "# 由 LazyCat-Scripts 管理：确保 OMZ / P10k 加载顺序正确且可重复执行。"
    echo 'export ZSH="$HOME/.oh-my-zsh"'
    echo 'typeset -ga plugins'
    echo 'typeset -gU plugins'
    echo "plugins+=( ${PLUGINS_LIST[*]} )"
    if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
        echo 'ZSH_THEME="powerlevel10k/powerlevel10k"'
        echo '[[ ! -f "$HOME/.p10k.zsh" ]] || source "$HOME/.p10k.zsh"'
        echo '# 如需生成/重跑向导：请在 Zsh 里手动执行 p10k configure'
    fi
    echo "# --- LAZYCAT-SCRIPTS ZSH MANAGED END ---"
} > "$LAZYCAT_BLOCK_FILE"

if zshrc_has_omz_source "$ZSHRC_FILE"; then
    # 已存在 source 行：把托管块插入到 source 之前，确保变量和 p10k 配置生效
    inject_lazycat_block_before_omz_source "$ZSHRC_FILE" "$LAZYCAT_BLOCK_FILE"
else
    # 不存在 source 行：追加一个包含 source 的托管块，保证 OMZ/主题/插件能实际加载
    LAZYCAT_BLOCK_WITH_SOURCE_FILE="$(mktemp)"
    {
        sed '$d' "$LAZYCAT_BLOCK_FILE"
        echo 'source "$ZSH/oh-my-zsh.sh"'
        echo '# --- LAZYCAT-SCRIPTS ZSH MANAGED END ---'
    } > "$LAZYCAT_BLOCK_WITH_SOURCE_FILE"
    append_lazycat_block "$ZSHRC_FILE" "$LAZYCAT_BLOCK_WITH_SOURCE_FILE"
    rm -f "$LAZYCAT_BLOCK_WITH_SOURCE_FILE"
fi
rm -f "$LAZYCAT_BLOCK_FILE"

commit_zshrc_edit
echo "✅ .zshrc 配置完成。"

echo '默认 Shell 保持不变；需要切换时请单独运行 chsh。'

# --- 完成后提示 ---
echo ""
echo "========================================================================"
echo "      🎉 Zsh 环境配置完成! 🎉"
echo "------------------------------------------------------------------------"
echo "  配置已提交并通过语法检查。请在新 Zsh 中检查实际加载结果。"
echo ""

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  1. 字体安装 (重要!):"
    echo "     为了完美显示 Powerlevel10k 的图标，您需要在您的终端里"
    echo "     安装并启用一个 Nerd Font 字体。推荐使用 'MesloLGS NF'。"
    echo "     您可以从这里下载: https://github.com/romkatv/powerlevel10k#meslo-nerd-font-patched-for-powerlevel10k"
    echo ""
fi

echo "  - 启动 Zsh:"
echo "     在当前窗口输入 'exec zsh' 来加载新配置。默认 Shell 未改变。"
echo ""

if [[ "$confirm_p10k" =~ ^[Yy]$ ]]; then
    echo "  - Powerlevel10k 配置:"
    echo "     需要主题向导时，在新 Zsh 中手动执行 p10k configure。"
fi
echo "========================================================================"

exit 0
