import unittest
from gate import failures
from affected import select

class RequiredChecks(unittest.TestCase):
    def test_success_and_known_failure(self):
        env=dict(MAPPING='success',QUALITY='success',ASSETS='success',EXPECT_ASSETS='true',EXPECT_BEHAVIOR='true',EXPECT_SYSTEM='true',
            BEHAVIOR='success',SYSTEM='success',WEEKLY='skipped',EVENT='pull_request')
        self.assertEqual(failures(env),[])
        for job in ('SYSTEM','ASSETS','BEHAVIOR'):
            for result in ('skipped','cancelled','failure',''):
                self.assertTrue(failures({**env,job:result}))
        for missing in ('EXPECT_BEHAVIOR','EXPECT_SYSTEM','QUALITY','MAPPING','EVENT','ASSETS','EXPECT_ASSETS'):
            candidate=dict(env);del candidate[missing]
            self.assertTrue(failures(candidate),missing)
        self.assertTrue(failures({**env,'EVENT':'schedule'}))
        self.assertEqual(failures({**env,'EVENT':'schedule','WEEKLY':'success'}),[])

    def test_docs_and_shared_dependency_mapping(self):
        self.assertFalse(select(['README.md'])['system'])
        for path in ('lib/file-transaction.sh','tests/gate.py','.github/workflows/reliability.yml','ssh/model.go'):
            selected=select([path])
            self.assertTrue(selected['system'],path);self.assertTrue(selected['behavior'],path)
