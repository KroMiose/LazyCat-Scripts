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
            root=Path(directory)
            versions=dict(scripts='lazycat-scripts-v1.0.0-rc.1',ssh='lazycat-ssh-v1.0.0-rc.1')
            names=[versions['scripts']+'.tar.gz','install-ssh.sh']+[versions['ssh']+'-'+system+'-'+arch+'.tar.gz' for system in ('linux','darwin') for arch in ('amd64','arm64')]
            assets=[]
            for name in names:
                (root/name).write_bytes(b'candidate')
                assets.append(dict(path=name,sha256=hashlib.sha256(b'candidate').hexdigest()))
            checksums=''.join(a['sha256']+'  '+a['path']+'\n' for a in assets)
            (root/'SHA256SUMS').write_text(checksums)
            base=dict(format_version=1,commit='fixture-sha',dirty=False,development=False,versions=versions,source_tree_sha256='a'*64,assets=assets,evidence={})
            reports={}
            requirements,digest=gate.release_contract()
            # Synthetic evidence exercises only the gate validator. It is not
            # a product test result and never enters release artifacts.
            observation=b'synthetic gate-unit-test observation\n'
            (root/'observation.log').write_bytes(observation)
            observed=dict(path='observation.log',sha256=hashlib.sha256(observation).hexdigest())
            for scope in ('fixed-environment','real-upstream','upgrade','failure-recovery','rollback','artifact-install','public-install'):
                reports[scope]=dict(source_tree_sha256='a'*64,commit='fixture-sha',status='passed',scope=scope,skipped=0,flaky=0,environment_errors=0,
                    contract_sha256=digest,scenarios=[dict(**{k:row[k] for k in ('id','environment','level')},status='passed',assertions={key:True for key in row['assertions']},observations=[observed]) for row in requirements[scope].values()],candidate_assets={a['path']:a['sha256'] for a in assets})
            def write(data,results):
                data=copy.deepcopy(data)
                for scope,result in results.items():
                    raw=json.dumps(result).encode();(root/(scope+'.json')).write_bytes(raw)
                    data['evidence'][scope]=dict(path=scope+'.json',sha256=hashlib.sha256(raw).hexdigest())
                path=root/'manifest.json';path.write_text(json.dumps(data));return path
            gate.verify(write(base,reports),'fixture-sha')
            for field,value in [('development',True),('dirty',True),('assets',assets+assets),('assets',assets[:-1])]:
                with self.subTest(field=field),self.assertRaises(ValueError):
                    gate.verify(write({**base,field:value},reports),'fixture-sha')
            for field,value in [('status','failed'),('skipped',1),('flaky',False),('environment_errors',None),('scenarios',1),('scenarios',[dict(id='fake',status='skipped')]),('candidate_assets',{}),('commit','old-sha'),('source_tree_sha256','b'*64)]:
                changed=copy.deepcopy(reports);changed['artifact-install'][field]=value
                with self.subTest(field=field,value=value),self.assertRaises(ValueError):
                    gate.verify(write(base,changed),'fixture-sha')
            for mutate in ('omit','rename','mock','platform','assertion','observation','contract'):
                changed=copy.deepcopy(reports);report=changed['fixed-environment'];scenario=report['scenarios'][0]
                if mutate=='omit':report['scenarios'].pop()
                elif mutate=='rename':scenario['id']='arbitrary-green-name'
                elif mutate=='mock':scenario['level']='mock'
                elif mutate=='platform':scenario['environment']='compiled-only-arm64'
                elif mutate=='assertion':scenario['assertions']['existing-config-preserved']=False
                elif mutate=='observation':scenario['observations']=[]
                else:report['contract_sha256']='old-contract'
                with self.subTest(mutate=mutate),self.assertRaises(ValueError):gate.verify(write(base,changed),'fixture-sha')
            changed=copy.deepcopy(reports);del changed['public-install']
            with self.assertRaises(ValueError):gate.verify(write(base,changed),'fixture-sha')
            path=write(base,reports)
            (root/'observation.log').write_bytes(b'tampered')
            with self.assertRaises(ValueError):gate.verify(path,'fixture-sha')
            (root/'observation.log').write_bytes(observation)
            (root/'SHA256SUMS').write_text(checksums+'duplicate\n')
            with self.assertRaises(ValueError):gate.verify(path,'fixture-sha')
            (root/'SHA256SUMS').write_text(checksums)
            (root/names[0]).write_bytes(b'changed after testing')
            with self.assertRaises(ValueError):gate.verify(path,'fixture-sha')
