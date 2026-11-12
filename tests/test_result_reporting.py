import io
import unittest
from run import Result, execution_differences

class ResultReporting(unittest.TestCase):
    def test_subtest_and_quarantine_never_disappear(self):
        class Broken(unittest.TestCase):
            def runTest(self):
                with self.subTest(case='known failure'):self.fail('fixture failure')
        class Quarantined(unittest.TestCase):
            @unittest.expectedFailure
            def runTest(self):self.fail('quarantine')
        class Skipped(unittest.TestCase):
            def runTest(self):
                with self.subTest(case='skip'):self.skipTest('not coverage')
        for case in (Broken,Quarantined,Skipped):
            result=unittest.TextTestRunner(stream=io.StringIO(),resultclass=Result).run(case())
            self.assertTrue(result.records)
            self.assertTrue(any(r['status']!='passed' for r in result.records))
            self.assertFalse(result.wasSuccessful() and not result.skipped)

    def test_discovered_but_unexecuted_case_is_incomplete(self):
        class Healthy(unittest.TestCase):
            def runTest(self):pass
        class SilentlyOmitted(unittest.TestCase):
            def run(self,result=None):return result
        healthy=Healthy();omitted=SilentlyOmitted()
        cases=[healthy,omitted]
        result=unittest.TextTestRunner(stream=io.StringIO(),resultclass=Result).run(unittest.TestSuite(cases))
        self.assertTrue(result.wasSuccessful())
        self.assertEqual(result.testsRun,1)
        self.assertEqual(execution_differences(cases,result),
            {'not_started':[omitted.id()],'not_finished':[omitted.id()],'unexpected':[]})
        complete=unittest.TextTestRunner(stream=io.StringIO(),resultclass=Result).run(Healthy())
        self.assertFalse(any(execution_differences([healthy],complete).values()))
