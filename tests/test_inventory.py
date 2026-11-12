import unittest
from inventory import differences

class Inventory(unittest.TestCase):
    def test_same_count_cannot_hide_replaced_or_missing_case(self):
        self.assertEqual(differences(['suite.install','suite.rollback'],['suite.install','suite.render']),
                         {'missing':['suite.rollback'],'unexpected':['suite.render']})
        self.assertEqual(differences(['suite.install'],['suite.install']),{'missing':[],'unexpected':[]})
        with self.assertRaises(ValueError):differences(['suite.install'],['suite.install','suite.install'])
