#!/usr/bin/env bash
# Manage only the explicitly selected user's supplemental docker membership.
set -euo pipefail
mode=add
target="${SUDO_USER:-}"
if [[ "${1:-}" == check || "${1:-}" == add || "${1:-}" == remove ]]; then mode="$1";shift;fi
if [[ "${1:-}" == --user && $# == 2 ]]; then target="$2";shift 2;fi
[[ $# == 0 && -n "$target" && "$target" != root && "$target" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || { echo '用法：[check|add|remove] --user <普通用户>；sudo 调用可沿用 SUDO_USER' >&2;exit 2; }
getent passwd "$target" >/dev/null || { echo '目标用户不存在' >&2;exit 2; }
getent group docker >/dev/null || { echo 'docker 组不存在，请先检查 Docker 安装' >&2;exit 1; }
member=0
id -nG "$target" | tr ' ' '\n' | grep -qx docker && member=1
if [[ "$mode" == check ]]; then printf '%s docker_membership=%s\n' "$target" "$member";exit 0;fi
[[ "$EUID" == 0 ]] || { echo '修改组成员关系需要 root' >&2;exit 2; }
if [[ "$mode" == add && "$member" == 1 || "$mode" == remove && "$member" == 0 ]]; then echo '成员关系已符合要求，无变化。';exit 0;fi
if [[ "$mode" == remove && "$(id -gn "$target")" == docker ]]; then echo 'docker 是此用户主组，需单独选择新主组；未修改' >&2;exit 3;fi
[[ ! -L /var/lib/lazycat ]] || exit 3
(umask 077;mkdir -p /var/lib/lazycat/group-operations)
operation=$(mktemp -d /var/lib/lazycat/group-operations/change.XXXXXX)
getent group docker > "$operation/before"
printf '%s\n%s\n' "$target" "$mode" > "$operation/request"
printf 'prepared\n' > "$operation/status"
if [[ "$mode" == add ]]; then usermod -aG docker "$target";else gpasswd -d "$target" docker;fi
getent group docker > "$operation/after"
actual=0
id -nG "$target" | tr ' ' '\n' | grep -qx docker && actual=1
if [[ "$mode" == add && "$actual" != 1 || "$mode" == remove && "$actual" != 0 ]]; then echo '组成员验证失败，检查操作记录' >&2;exit 1;fi
printf 'committed\n' > "$operation/status"
printf '成员关系已更新：%s。已有登录进程的组权限不会自动改变。记录：%s\n' "$target" "$operation"
