"""Unit tests for the Issue agent scripts: python3 -m unittest discover scripts/agent/tests"""
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import agentctl  # noqa: E402
import agentlib  # noqa: E402
import appstoreconnect  # noqa: E402
import prototype  # noqa: E402


def comment(identifier, login='owner', association='OWNER', kind='User', body='hello'):
    return {'id': identifier, 'user': {'login': login, 'type': kind}, 'author_association': association,
            'body': body, 'created_at': '2026-10-10T00:00:00Z'}


class PendingCommentsTests(unittest.TestCase):
    def setUp(self):
        os.environ.pop('AGENT_ALLOWED_USERS', None)

    def test_only_new_comments_from_allowed_people(self):
        comments = [
            comment(1), comment(5),
            comment(6, 'github-actions[bot]', 'NONE', 'Bot'),
            comment(7, 'stranger', 'NONE'),
            comment(8, body=f'{agentlib.REPLY_MARKER} reply'),
            comment(9, 'member', 'COLLABORATOR'),
        ]
        pending = agentlib.pending_comments(comments, {'lastCommentId': 4})
        self.assertEqual([item['id'] for item in pending], [5, 9])

    def test_explicit_allow_list_overrides_association(self):
        with mock.patch.dict(os.environ, {'AGENT_ALLOWED_USERS': 'Alice'}):
            comments = [comment(1, 'alice', 'NONE'), comment(2, 'owner', 'OWNER')]
            self.assertEqual([item['id'] for item in agentlib.pending_comments(comments, {})], [1])

    def test_issue_body_is_pending_once(self):
        issue = {'user': {'login': 'owner'}, 'author_association': 'OWNER'}
        self.assertTrue(agentlib.issue_is_pending(issue, {}))
        self.assertFalse(agentlib.issue_is_pending(issue, {'issueBodyProcessed': True}))


class ExecutionAnalysisTests(unittest.TestCase):
    def test_usage_and_first_request(self):
        messages = [
            {'type': 'system', 'subtype': 'init', 'session_id': 's', 'model': 'claude-opus-5-5', 'tools': ['Bash']},
            {'type': 'assistant', 'parent_tool_use_id': None, 'message': {'id': 'a', 'content': [{'type': 'text', 'text': 'x'}],
             'usage': {'input_tokens': 2, 'cache_read_input_tokens': 90, 'cache_creation_input_tokens': 8,
                       'cache_creation': {'ephemeral_1h_input_tokens': 8}}}},
            {'type': 'assistant', 'parent_tool_use_id': 'tool', 'message': {'id': 'sub', 'content': [], 'usage': {}}},
            {'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'done', 'session_id': 's',
             'usage': {'input_tokens': 4, 'cache_read_input_tokens': 180, 'cache_creation_input_tokens': 16, 'output_tokens': 50}},
        ]
        report = agentctl.analyze(messages)
        self.assertEqual(report['sessionId'], 's')
        self.assertEqual(report['requests'], 1)
        self.assertEqual(report['firstRequest']['cacheCreation1h'], 8)
        self.assertAlmostEqual(report['turnUsage']['cacheHitRate'], 0.9)

    def test_missing_result_has_no_hit_rate(self):
        report = agentctl.analyze([])
        self.assertIsNone(report['result'])
        self.assertIsNone(report['turnUsage']['cacheHitRate'])


class SessionArchiveTests(unittest.TestCase):
    def test_round_trip_through_store(self):
        stored = {}

        class FakeStore:
            def put(self, key, data, content_type):
                stored[key] = data

            def get(self, key):
                return stored.get(key)

        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            projects = Path(first) / 'projects' / '-Users-runner-work-struis-ios-struis-ios'
            projects.mkdir(parents=True)
            (projects / 'abc.jsonl').write_text('{"type":"user"}\n')
            with mock.patch.object(agentctl, 'CLAUDE_DIR', Path(first)):
                agentctl.save_session(FakeStore(), 3)
            with mock.patch.object(agentctl, 'CLAUDE_DIR', Path(second)):
                self.assertTrue(agentctl.restore_session(FakeStore(), 3, 'abc'))
                self.assertFalse(agentctl.restore_session(FakeStore(), 3, 'other'))

    def test_archive_rejects_path_traversal(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
            info = tarfile.TarInfo('../escape.txt')
            info.size = 1
            archive.addfile(info, io.BytesIO(b'x'))

        class FakeStore:
            def get(self, key):
                return buffer.getvalue()

        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(agentctl, 'CLAUDE_DIR', Path(directory) / 'claude'):
                with self.assertRaises(tarfile.FilterError):
                    agentctl.restore_session(FakeStore(), 3, 'abc')
            self.assertFalse((Path(directory) / 'escape.txt').exists())


class PrototypeTests(unittest.TestCase):
    def test_slot_identifiers(self):
        self.assertEqual(prototype.slot_name(7), 's07')
        record = prototype.slot_record('s07')
        self.assertEqual(record['bundleBase'], f'{prototype.PREFIX}.s07')
        self.assertEqual(record['appGroup'], f'group.{prototype.PREFIX}.s07')

    def test_redaction(self):
        with mock.patch.dict(os.environ, {'STRUIS_DELIVERY_APP_KEY': 'delivery-secret'}):
            text = prototype.redact('export STRUIS_DELIVERY_APP_KEY\\=delivery-secret and delivery-secret')
        self.assertNotIn('delivery-secret', text)

    def test_workspace_patch_changes_only_the_checkout_identity(self):
        source = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (prototype.WORKER_SOURCE, 'Info.plist', prototype.ICON):
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_bytes((source / relative).read_bytes())
            (root / 'Config').mkdir()
            meta = {'issue': 2, 'variant': 'b', 'bundleId': 'com.example.preview.s01'}
            with mock.patch.object(prototype, 'run') as run, mock.patch.dict(os.environ, {'STRUIS_DELIVERY_APP_KEY': ''}):
                name = prototype.patch_workspace(meta, 1, root)
            self.assertEqual(name, '2B Struis')
            self.assertIn('host: "com.example.preview.s01"', (root / prototype.WORKER_SOURCE).read_text())
            self.assertIn('badge_icon.swift', str(run.call_args[0][0][1]))


class AppStoreConnectTests(unittest.TestCase):
    def test_der_signature_conversion(self):
        r = (1).to_bytes(1, 'big')
        s = (0x80).to_bytes(1, 'big')
        der = bytes([0x30, 7, 0x02, 1]) + r + bytes([0x02, 2, 0x00]) + s
        raw = appstoreconnect._der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(int.from_bytes(raw[:32], 'big'), 1)
        self.assertEqual(int.from_bytes(raw[32:], 'big'), 0x80)


if __name__ == '__main__':
    unittest.main()


class PullRequestCITests(unittest.TestCase):
    def test_request_pr_creates_pr_then_dispatches_ci_without_running_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'run.json').write_text(json.dumps({'branch': 'agent/issue-4'}))
            body = home / 'pr.md'
            body.write_text('Refs #4')
            gh = mock.Mock(repository='owner/repo')
            gh.get.return_value = []
            gh.request.side_effect = [({'html_url': 'https://github.com/owner/repo/pull/9'}, {}), ({}, {}), ({}, {})]
            args = mock.Mock(title='Fix', body_file=str(body))
            with mock.patch.object(agentctl, 'agent_home', return_value=home), mock.patch.object(agentctl, 'GitHub', return_value=gh), mock.patch.object(agentctl, 'git', side_effect=['', '', 'abc', 'abc']), mock.patch.object(agentctl, 'outbox_append'):
                agentctl.cmd_request_pr(args)
            self.assertEqual([call.args[1] for call in gh.request.call_args_list], [
                '/repos/owner/repo/pulls',
                '/repos/owner/repo/actions/workflows/ios.yml/dispatches',
                '/repos/owner/repo/actions/workflows/agent-tests.yml/dispatches'])
            self.assertEqual(gh.request.call_args_list[1].args[2], {'ref': 'agent/issue-4'})

    def test_uncommitted_work_does_not_create_pr(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'run.json').write_text(json.dumps({'branch': 'agent/issue-4'}))
            with mock.patch.object(agentctl, 'agent_home', return_value=home), mock.patch.object(agentctl, 'git', return_value=' M file'), mock.patch.object(agentctl, 'GitHub') as gh:
                with self.assertRaises(SystemExit):
                    agentctl.cmd_request_pr(mock.Mock())
                gh.assert_not_called()
