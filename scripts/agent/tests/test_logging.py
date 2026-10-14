"""Live logging must show useful progress without changing execution messages."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import configure_logging


class LiveLoggingTests(unittest.TestCase):
    def test_sdk_events_are_visible_and_credentials_and_hidden_blocks_are_not(self):
        script = r'''
const assert = require('node:assert/strict');
const {formatLiveMessage, redact} = require(process.argv[1]);
const env = {GITHUB_TOKEN:'ghp_private_sample_value_123456789', CUSTOM_API_KEY:'private-value-without-prefix'};
const msg = {type:'assistant', message:{content:[
 {type:'thinking', thinking:'hidden-reasoning'},
 {type:'text', text:'個別テストを確認します'},
 {type:'tool_use', name:'Bash', id:'tool-1', input:{command:'xcodebuild test -only-testing:Example'}}]}};
const before = JSON.stringify(msg);
const log = formatLiveMessage(msg, env);
assert(log.includes('個別テストを確認します'));
assert(log.includes('xcodebuild test -only-testing:Example'));
assert(!log.includes('hidden-reasoning'));
assert.equal(JSON.stringify(msg), before);
const result = formatLiveMessage({type:'user', message:{content:[{type:'tool_result',tool_use_id:'tool-1',is_error:true,
 content:'failed: '+env.CUSTOM_API_KEY+'\n::warning::untrusted\n'+env.GITHUB_TOKEN}]}}, env);
assert(result.includes('[失敗]'));
assert(!result.includes(env.GITHUB_TOKEN));
assert(!result.includes(env.CUSTOM_API_KEY));
assert(result.split('\n').every(line => line.startsWith('[Claude] ')));
assert.equal(formatLiveMessage({type:'user',message:{content:[{type:'text',text:'private prompt'}]}}, env), null);
const multiline = '-----BEGIN PRIVATE KEY-----\nabc123private\n-----END PRIVATE KEY-----';
assert(!redact(multiline, {}).includes('abc123private'));
assert(!redact('Authorization: Bearer unknown-credential-value', {}).includes('unknown-credential-value'));
assert(!redact('api_key="unknown-secret-value"', {}).includes('unknown-secret-value'));
assert(!redact(JSON.stringify({value:env.CUSTOM_API_KEY}), env).includes(env.CUSTOM_API_KEY));
const huge = formatLiveMessage({type:'user',message:{content:[{type:'tool_result',tool_use_id:'t', content:'a'.repeat(40000)}]}}, env);
assert(huge.includes('省略'));
assert(huge.length < 25000);
'''
        helper = Path(__file__).resolve().parents[1] / 'live-log.cjs'
        subprocess.run(['node', '-e', script, str(helper)], check=True)

    def test_patch_changes_display_only_and_rejects_unknown_action_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'base-action/src/run-claude-sdk.ts'
            source.parent.mkdir(parents=True)
            original = configure_logging.MARKER + '  return null;\n}\n// query execution stays intact\n'
            source.write_text(original)
            with self.assertRaises(RuntimeError):
                configure_logging.configure(root)
            self.assertEqual(source.read_text(), original)
            with mock.patch.object(configure_logging, 'SOURCE_SHA256', hashlib.sha256(original.encode()).hexdigest()):
                configure_logging.configure(root)
            patched = source.read_text()
            self.assertIn('formatLiveMessage(message)', patched)
            self.assertTrue(patched.endswith('// query execution stays intact\n'))
            self.assertTrue(source.with_name('struis-live-log.cjs').exists())
