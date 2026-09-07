"""The release gate must reject plausible-looking but incomplete green reports."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('release_check',ROOT/'scripts/release_check.py')
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)

class ReleaseGate(unittest.TestCase):
    def test_findings_cannot_be_omitted_or_implicitly_accepted(self):
        items=[dict(id=i,release_complete=True) for i in range(1,43)]
        gate.verify_acceptance({'items':items})
        for changed in (items[:-1],items+[items[0]],[{**item,'id':1} for item in items],[{**item,'release_complete':1} for item in items],[{**item,'release_complete':False} for item in items]):
            with self.assertRaises(ValueError):gate.verify_acceptance({'items':changed})

    def test_exact_artifacts_and_independent_scenarios(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'binary').write_bytes(b'candidate')
            assets=[{'path':'binary','sha256':hashlib.sha256(b'candidate').hexdigest()}]
            base=dict(format_version=1,commit='fixture-sha',dirty=False,development=False,assets=assets,evidence={})
            reports={}
            for scope in ('fixed-environment','real-upstream','upgrade','failure-recovery','rollback','artifact-install','public-install'):
                reports[scope]=dict(commit='fixture-sha',status='passed',scope=scope,skipped=0,flaky=0,environment_errors=0,
                    scenarios=[dict(id='actual-entrypoint',status='passed')],candidate_assets={'binary':assets[0]['sha256']})
            def write(data,results):
                data=copy.deepcopy(data)
                for scope,result in results.items():
                    raw=json.dumps(result).encode();(root/(scope+'.json')).write_bytes(raw)
                    data['evidence'][scope]=dict(path=scope+'.json',sha256=hashlib.sha256(raw).hexdigest())
                path=root/'manifest.json';path.write_text(json.dumps(data));return path
            gate.verify(write(base,reports),'fixture-sha')
            for field,value in [('development',True),('dirty',True),('assets',assets+assets)]:
                with self.subTest(field=field),self.assertRaises(ValueError):
                    gate.verify(write({**base,field:value},reports),'fixture-sha')
            for field,value in [('status','failed'),('skipped',1),('flaky',False),('environment_errors',None),('scenarios',1),('scenarios',[dict(id='fake',status='skipped')]),('candidate_assets',{}),('commit','old-sha')]:
                changed=copy.deepcopy(reports);changed['artifact-install'][field]=value
                with self.subTest(field=field,value=value),self.assertRaises(ValueError):
                    gate.verify(write(base,changed),'fixture-sha')
            changed=copy.deepcopy(reports);del changed['public-install']
            with self.assertRaises(ValueError):gate.verify(write(base,changed),'fixture-sha')
            path=write(base,reports);(root/'binary').write_bytes(b'changed after testing')
            with self.assertRaises(ValueError):gate.verify(path,'fixture-sha')
