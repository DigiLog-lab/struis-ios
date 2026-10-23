"""Prototype identifier slots: archiving frees a slot, the next new prototype takes it."""
import argparse
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentctl  # noqa: E402
import prototype  # noqa: E402
from gate_fakes import MemoryStore  # noqa: E402

WORKFLOW: Path = Path(__file__).resolve().parents[3] / '.github/workflows/agent-prototype.yml'


def registry(owners: dict[str, tuple[int, str] | None]) -> dict:
    slots: dict = {}
    for name, owner in owners.items():
        slots[name] = {**prototype.slot_record(name), 'registeredAt': '2026-10-10T00:00:00Z',
                       'assigned': {'issue': owner[0], 'variant': owner[1], 'at': '2026-10-10T00:00:00Z'} if owner else None}
    return {'version': 1, 'prefix': prototype.PREFIX, 'slots': slots}


def allocate_args(issue: int, variant: str, ref: str) -> argparse.Namespace:
    return argparse.Namespace(issue=issue, variant=variant, ref=ref, title='案', summary='要約')


class PrototypeSlotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.store: MemoryStore = MemoryStore()
        # s01-s05 registered on the portal and in use; s06 exists in the store but is the next free name.
        self.store.put_json(prototype.SLOTS_KEY, registry({
            's01': (2, 'a'), 's02': (2, 'b'), 's03': (4, 'a'), 's04': (6, 'a'), 's05': (4, 'b'), 's06': None}))
        for issue, variant, slot in ((2, 'a', 's01'), (2, 'b', 's02'), (4, 'a', 's03'), (6, 'a', 's04'), (4, 'b', 's05')):
            record: dict = prototype.slot_record(slot)
            self.store.put_json(prototype.meta_key(issue, variant), {
                'issue': issue, 'variant': variant, 'slot': slot, 'bundleId': record['bundleBase'],
                'appGroup': record['appGroup'], 'builds': [{'buildNumber': 3}]})
        self.patches = [mock.patch.object(prototype, 'Store', return_value=self.store),
                        mock.patch.object(prototype, 'write_output'),
                        mock.patch.object(prototype, 'append_summary')]
        for patch in self.patches:
            patch.start()

    def tearDown(self) -> None:
        for patch in self.patches:
            patch.stop()

    def slots(self) -> dict:
        return self.store.get_json(prototype.SLOTS_KEY)['slots']

    def test_archive_frees_the_slot_and_the_next_new_prototype_takes_it(self) -> None:
        with mock.patch('builtins.print'):
            prototype.cmd_archive(argparse.Namespace(issue=2, variant='a', note='比較が終わった'))
        self.assertIsNone(self.slots()['s01']['assigned'])
        self.assertIn('released', self.store.get_json(prototype.meta_key(2, 'a')))
        with mock.patch('builtins.print'):
            prototype.cmd_allocate(allocate_args(46, 'a', 'agent/issue-46'))
        meta: dict = self.store.get_json(prototype.meta_key(46, 'a'))
        # Name order: the released s01 comes before the unregistered s06.
        self.assertEqual(meta['slot'], 's01')
        self.assertEqual(meta['bundleId'], f'{prototype.PREFIX}.s01')
        self.assertEqual(meta['branch'], 'agent/issue-46')
        self.assertEqual(self.slots()['s01']['assigned']['issue'], 46)
        self.assertIsNone(self.slots()['s06']['assigned'])

    def test_rebuilding_an_archived_prototype_takes_a_slot_again(self) -> None:
        prototype.release_slot(self.store, 4, 'b')
        prototype.release_slot(self.store, 2, 'a')
        with mock.patch('builtins.print'):
            prototype.cmd_allocate(allocate_args(4, 'b', 'prototype/4/b'))
        meta: dict = self.store.get_json(prototype.meta_key(4, 'b'))
        self.assertEqual(meta['slot'], 's01')
        self.assertNotIn('released', meta)
        self.assertEqual(meta['builds'], [{'buildNumber': 3}])
        owner: dict = self.slots()['s01']['assigned']
        self.assertEqual((owner['issue'], owner['variant']), (4, 'b'))
        self.assertIsNone(self.slots()['s05']['assigned'])

    def test_rebuild_after_an_archive_cut_short_takes_a_slot_again(self) -> None:
        # The archive freed s05 in the registry but stopped before marking meta.json.
        self.store.update_json(prototype.SLOTS_KEY, lambda document: {
            **document, 'slots': {**document['slots'], 's05': {**document['slots']['s05'], 'assigned': None}}})
        with mock.patch('builtins.print'):
            prototype.cmd_allocate(allocate_args(46, 'a', 'agent/issue-46'))
            prototype.cmd_allocate(allocate_args(4, 'b', 'prototype/4/b'))
        self.assertEqual(self.store.get_json(prototype.meta_key(46, 'a'))['slot'], 's05')
        # 4/b must not keep using s05, which 46/a now owns.
        self.assertEqual(self.store.get_json(prototype.meta_key(4, 'b'))['slot'], 's06')

    def test_a_prototype_that_keeps_its_slot_is_not_moved(self) -> None:
        prototype.release_slot(self.store, 2, 'a')
        with mock.patch('builtins.print'):
            prototype.cmd_allocate(allocate_args(4, 'b', 'agent/issue-4'))
        self.assertEqual(self.store.get_json(prototype.meta_key(4, 'b'))['slot'], 's05')
        self.assertIsNone(self.slots()['s01']['assigned'])

    def test_no_free_slot_stops_with_the_way_to_free_one(self) -> None:
        self.store.update_json(prototype.SLOTS_KEY, lambda document: {
            **document, 'slots': {name: record for name, record in document['slots'].items() if name != 's06'}})
        with self.assertRaises(SystemExit) as raised:
            prototype.cmd_allocate(allocate_args(46, 'a', 'agent/issue-46'))
        self.assertIn('アーカイブ', str(raised.exception))
        self.assertIsNone(self.store.get_json(prototype.meta_key(46, 'a')))

    def test_archiving_a_prototype_without_a_slot_changes_nothing(self) -> None:
        before: dict = self.slots()
        self.assertIsNone(prototype.release_slot(self.store, 99, 'z'))
        self.assertEqual(self.slots(), before)

    def test_agent_archived_status_releases_the_slot(self) -> None:
        agentctl.record_prototype_events(self.store, 6, [{'variant': 'a', 'status': 'archived', 'note': '済み'}], 'agent')
        self.assertIsNone(self.slots()['s04']['assigned'])
        events: list[dict] = [json.loads(value) for key, value in self.store.data.items()
                              if key.startswith('prototypes/6/a/events/')]
        self.assertEqual([(event['status'], event['releasedSlot']) for event in events], [('archived', 's04')])

    def test_agent_other_status_keeps_the_slot(self) -> None:
        agentctl.record_prototype_events(self.store, 6, [{'variant': 'a', 'status': 'testing'}], 'agent')
        self.assertEqual(self.slots()['s04']['assigned']['issue'], 6)


class PrototypeWorkflowTests(unittest.TestCase):
    def test_build_accepts_any_branch_and_checks_it_exists(self) -> None:
        text: str = WORKFLOW.read_text()
        self.assertNotIn('ref must be prototype/', text)
        self.assertIn('git check-ref-format --branch "$REF"', text)
        self.assertIn('git/ref/heads/$encoded', text)
        self.assertIn("ref: refs/heads/${{ (inputs.ref || github.event.client_payload.ref) }}", text)

    def test_build_and_archive_of_one_prototype_share_a_concurrency_group(self) -> None:
        group: str = WORKFLOW.read_text().split('\nconcurrency:\n', 1)[1].split('cancel-in-progress', 1)[0]
        self.assertIn("format('agent-prototype-{0}-{1}'", group)
        self.assertNotIn("format('agent-prototype-{0}-{1}-{2}'", group)

    def test_archive_job_needs_no_signing_secret(self) -> None:
        text: str = WORKFLOW.read_text()
        archive: str = text.split('\n  archive:\n', 1)[1].split('\n  build:\n', 1)[0]
        self.assertNotIn('secrets.', archive)
        self.assertNotIn('environment:', archive)
        self.assertIn('prototype.py archive', archive)


if __name__ == '__main__':
    unittest.main()
