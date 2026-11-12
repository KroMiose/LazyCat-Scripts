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
# The observer is supplied by this image, not a product dependency.
python3 - <<'PY'
import os
os.setxattr(os.path.expanduser('~/.config/user-dirs.dirs'), 'user.lazycat-fixture', b'keep metadata')
PY
cp "$HOME/.config/user-dirs.dirs" /tmp/before-xdg
bash /work/linux/setup_en_dirs.sh --check
cmp "$HOME/.config/user-dirs.dirs" /tmp/before-xdg
bash /work/linux/setup_en_dirs.sh --apply --move-files
python3 - <<'PY'
import os
assert os.getxattr(os.path.expanduser('~/.config/user-dirs.dirs'), 'user.lazycat-fixture') == b'keep metadata'
PY
[[ -f "$HOME/Downloads/user-file" && ! -e "$HOME/原下载" ]]
grep -qx 'XDG_DOWNLOAD_DIR="$HOME/Downloads"' "$HOME/.config/user-dirs.dirs"
cp "$HOME/.config/user-dirs.dirs" /tmp/after-xdg
bash /work/linux/setup_en_dirs.sh --apply
cmp "$HOME/.config/user-dirs.dirs" /tmp/after-xdg
operation=("$HOME/.config/user-dirs.dirs.lazycat-operation."*)
[[ ${#operation[@]} == 1 ]]
bash /work/common/lazycat-check.sh rollback "${operation[0]}"
cmp "$HOME/.config/user-dirs.dirs" /tmp/before-xdg
python3 - <<'PY'
import os
assert os.getxattr(os.path.expanduser('~/.config/user-dirs.dirs'), 'user.lazycat-fixture') == b'keep metadata'
PY
# File rollback does not promise to reverse an explicit directory move.
[[ -f "$HOME/Downloads/user-file" ]]
echo 'PASS Linux XDG real file move, user preference preservation and repeat'

# Native xattr concurrency observer; only user files, no network or services.
python3 -B -m unittest discover -s /work/tests -p test_transaction_attributes.py
