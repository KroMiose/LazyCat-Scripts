import io
import unittest
from run import Result

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
