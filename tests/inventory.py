#!/usr/bin/env python3
"""Reviewed Python case inventory; completeness is separate from correctness."""
import argparse
import json
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
INVENTORY=ROOT/'tests/python-cases.json'

def flatten(suite):
    for item in suite:
        if isinstance(item,unittest.TestSuite):yield from flatten(item)
        else:yield item

def collect():
    tests=list(flatten(unittest.TestLoader().discover(str(ROOT/'tests'))))
    tests+=list(flatten(unittest.TestLoader().discover(str(ROOT/'ssh/tests'))))
    return tests

def differences(expected,actual):
    if len(expected)!=len(set(expected)) or len(actual)!=len(set(actual)):
        raise ValueError('duplicate Python test IDs')
    return {'missing':sorted(set(expected)-set(actual)),'unexpected':sorted(set(actual)-set(expected))}

def check(tests):
    data=json.loads(INVENTORY.read_text())
    if data['format_version']!=1 or not data['tests']:
        raise ValueError('invalid or empty Python test inventory')
    return differences(data['tests'],[case.id() for case in tests])

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--write',action='store_true');args=parser.parse_args()
    tests=collect()
    if args.write:
        ids=sorted(test.id() for test in tests)
        if any('_FailedTest' in identifier for identifier in ids):
            raise SystemExit('test imports failed; refusing to record an incomplete inventory')
        differences(ids,ids)
        INVENTORY.write_text(json.dumps({'format_version':1,'scope':'Python isolated/adapted cases only; Go, native scripts and VM scenarios have separate evidence','tests':ids},indent=2)+'\n')
    else:
        delta=check(tests)
        if any(delta.values()):raise SystemExit(json.dumps(delta,indent=2))
        print('PASS reviewed Python case inventory; not a claim of product coverage')

if __name__=='__main__':main()
