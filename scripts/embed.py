#!/usr/bin/env python3
"""Keep single-file download entries self-contained without runtime cache loading."""
from pathlib import Path
import argparse
ROOT=Path(__file__).resolve().parents[1]
BEGIN='# lazycat-file-transaction:begin'
END='# lazycat-file-transaction:end'
p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');args=p.parse_args()
block=BEGIN+'\n'+(ROOT/'lib/file-transaction.sh').read_text()+END
for folder in ('common','linux'):
    for path in (ROOT/folder).glob('*.sh'):
        data=path.read_text()
        if BEGIN not in data:continue
        start=data.index(BEGIN);end=data.index(END,start)+len(END)
        candidate=data[:start]+block+data[end:]
        if args.check:
            if candidate!=data:raise SystemExit('Embedded helper out of date: '+str(path))
        else:path.write_text(candidate)
