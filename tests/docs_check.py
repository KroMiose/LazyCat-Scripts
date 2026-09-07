#!/usr/bin/env python3
"""Check internal Markdown file links and pinned external Actions."""
from pathlib import Path
import re
from urllib.parse import unquote,urlsplit
ROOT=Path(__file__).resolve().parents[1]
errors=[]
for path in [ROOT/'README.md',ROOT/'COMMANDS.md',*list((ROOT/'docs').glob('*.md')),ROOT/'common/README.md',ROOT/'linux/README.md',ROOT/'ssh/README.md']:
    text=re.sub(r'```.*?```','',path.read_text(),flags=re.S)
    for raw in re.findall(r'\]\(([^\n)]+)\)',text):
        target=raw.strip('<>')
        if target.startswith('#') or urlsplit(target).scheme:continue
        target=unquote(target.split('#')[0])
        if not target:continue
        if not (path.parent/target).exists():errors.append(f'{path.relative_to(ROOT)}: missing link {target}')
for path in (ROOT/'.github/workflows').glob('*.yml'):
    for action in re.findall(r'uses:\s+([^\s#]+)',path.read_text()):
        if action.startswith('./'):continue
        if not re.fullmatch(r'[^@]+@[0-9a-f]{40}',action):errors.append(f'{path.name}: unpinned action {action}')
if errors:raise SystemExit('\n'.join(errors))
print('PASS internal file links and pinned Actions (anchors and external URLs are separate coverage)')
