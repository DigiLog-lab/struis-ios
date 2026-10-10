#!/usr/bin/env python3
"""Pinned generation/source wiring checks; actual-source execution is separate."""
import hashlib,json,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1];SOURCE=ROOT/'Vendor/codex-source'
FILES=['skills/src/lib.rs','ext/skills/src/loader/host.rs','ext/skills/src/lib.rs','ext/skills/src/host_snapshot.rs','ext/skills/src/host_service.rs','ext/skills/src/host_prompt.rs','ext/skills/src/provider/host.rs','ext/skills/src/hyotan_skill_filesystem.rs','core/src/session/turn_context.rs','app-server/src/message_processor_tracing_tests/hyotan_captured_turn_tests.rs','app-server/src/message_processor_tracing_tests/hyotan_host_skill_tests.rs']
def snapshot():return {name:hashlib.sha256((SOURCE/'codex-rs'/name).read_bytes()).hexdigest() for name in FILES}
subprocess.run([sys.executable,ROOT/'Scripts/prepare-codex.py'],check=True);first=snapshot()
subprocess.run([sys.executable,ROOT/'Scripts/prepare-codex.py'],check=True);assert first==snapshot()
subprocess.run([sys.executable,ROOT/'Scripts/prepare-host-skills.py'],check=True);assert first==snapshot()
def text(name):return (SOURCE/'codex-rs'/name).read_text()
context=text('core/src/session/turn_context.rs')
assert context.index('let mut turn_context: TurnContext = Self::make_turn_context(')<context.index('// Hyotan captured skill snapshot starts here.')
assert 'let mut skill_preparation_guard = crate::hyotan_turn_lease::LeaseGuard(turn_context.hyotan_lease.clone())' in context
assert 'snapshot_for_captured_turn(&input, fs, environment.sandbox_context(None), check.clone())' in context
service=text('ext/skills/src/host_service.rs')
protected=service[service.index('    pub async fn snapshot_for_captured_turn('):service.index('    pub fn clear_cache(')]
assert 'None, None).await' in protected
assert 'root.file_system = workspace.clone()' in protected
assert 'canonicalize_if_exists' not in protected
assert 'self.codex_home' in protected and 'SkillFileSystem::embedded' in protected
snapshot_source=text('ext/skills/src/host_snapshot.rs')
assert 'ok_or_else(crate::hyotan_skill_filesystem::denied)' in snapshot_source
assert 'loaded == skill' in snapshot_source
assert snapshot_source.count('self.check()?')==2
assert 'prompts.fragments.clear()' in text('ext/skills/src/host_prompt.rs')
# Workspace capabilities refuse directory-symlink walks; discovery must not ask for them.
assert 'DirectorySymlinkPolicy::Follow' not in text('ext/skills/src/loader/host.rs')
assert 'host_snapshot.sanitize_error' in text('ext/skills/src/provider/host.rs')
assert 'actual MessageProcessor turn must inject authorized captured skill bytes' in text(FILES[-2])
print('PASS pinned full+standalone generation idempotence; captured snapshot/prompt/provider wiring')
print(json.dumps(first,indent=2))
print('LIMIT source assertions are not Core/AppServer/Apple runtime evidence; product issuer/body mode remain disabled.')
