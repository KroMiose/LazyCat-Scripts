#!/usr/bin/env bash
# File behavior only: no external network, real Linux user account and coreutils.
set -euo pipefail
[[ "$HOME" == /home/node && "$(id -u)" == 1000 ]]
mkdir -p "$HOME/.config" "$HOME/原下载"
printf 'keep\n' > "$HOME/原下载/user-file"
for kind in DESKTOP DOWNLOAD TEMPLATES PUBLICSHARE DOCUMENTS MUSIC PICTURES VIDEOS; do
    if [[ "$kind" == DOWNLOAD ]]; then value='$HOME/原下载';else value='$HOME';fi
    printf 'XDG_%s_DIR="%s"\n' "$kind" "$value"
done > "$HOME/.config/user-dirs.dirs"
cp "$HOME/.config/user-dirs.dirs" /tmp/before-xdg
bash /work/linux/setup_en_dirs.sh --check
cmp "$HOME/.config/user-dirs.dirs" /tmp/before-xdg
bash /work/linux/setup_en_dirs.sh --apply --move-files
[[ -f "$HOME/Downloads/user-file" && ! -e "$HOME/原下载" ]]
grep -qx 'XDG_DOWNLOAD_DIR="$HOME/Downloads"' "$HOME/.config/user-dirs.dirs"
cp "$HOME/.config/user-dirs.dirs" /tmp/after-xdg
bash /work/linux/setup_en_dirs.sh --apply
cmp "$HOME/.config/user-dirs.dirs" /tmp/after-xdg
echo 'PASS Linux XDG real file move, user preference preservation and repeat'
