import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('land', Path(__file__).resolve().parents[2] / 'scripts/land_pr.py')
land = importlib.util.module_from_spec(spec)
spec.loader.exec_module(land)


class CheckedHead(unittest.TestCase):
    def row(self):
        return {'number': 1, 'baseRefName': 'main', 'headRepositoryOwner': {'login': 'guaji67'},
                'headRefOid': 'a'*40, 'state': 'OPEN', 'isDraft': False, 'mergeable': 'MERGEABLE',
                'mergeStateStatus': 'CLEAN', 'statusCheckRollup': []}

    def test_same_verified_head(self):
        self.assertEqual(land.checked_pr(self.row(), 1, 'a'*40), [])

    def test_changed_head_target_fork_and_draft_rejected(self):
        for patch in [{'headRefOid':'b'*40}, {'baseRefName':'other'}, {'number':2},
                      {'headRepositoryOwner':{'login':'other'}}, {'isDraft':True},
                      {'mergeable':'CONFLICTING'}, {'mergeStateStatus':'BEHIND'}]:
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                land.checked_pr({**self.row(), **patch}, 1, 'a'*40)

    def test_failed_pending_and_missing_checks_rejected(self):
        for checks in [None, [{'status':'IN_PROGRESS'}], [{'status':'COMPLETED','conclusion':'FAILURE'}],
                       [{'status':'COMPLETED','conclusion':'SKIPPED'}], [{'status':'COMPLETED','conclusion':'NEUTRAL'}]]:
            with self.subTest(checks=checks), self.assertRaises(ValueError):
                land.checked_pr({**self.row(),'statusCheckRollup':checks}, 1, 'a'*40)
