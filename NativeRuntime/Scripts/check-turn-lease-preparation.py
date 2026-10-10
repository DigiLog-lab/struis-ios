#!/usr/bin/env python3
"""Pinned generation assertions; compilation/runtime evidence is separate."""
import hashlib, pathlib, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Vendor/codex-source'
FILES = ['Cargo.lock','core/Cargo.toml','core/src/lib.rs','core/src/codex_thread.rs','core/src/hyotan_turn_lease.rs','core/src/session/turn_context.rs','core/src/session/review.rs','core/src/session/mod.rs','core/src/tasks/mod.rs','core/src/prompt_debug.rs','core/src/tools/handlers/view_image.rs','protocol/src/models.rs','app-server/src/lib.rs','app-server/Cargo.toml','app-server/src/message_processor.rs','app-server/src/message_processor_tracing_tests.rs','app-server/src/message_processor_tracing_tests/hyotan_captured_turn_tests.rs']
def snapshot():
    return {path: hashlib.sha256((SOURCE/'codex-rs'/path).read_bytes()).hexdigest() for path in FILES}
subprocess.run([sys.executable, str(ROOT/'Scripts/prepare-codex.py')],check=True)
first=snapshot()
subprocess.run([sys.executable, str(ROOT/'Scripts/prepare-codex.py')],check=True)
assert first==snapshot(), 'non-idempotent turn/media generation'
def source(path): return (SOURCE/'codex-rs'/path).read_text()
assert 'prepare_local_media(&turn_context.hyotan_lease, input).await' in source('core/src/session/mod.rs')
assert 'response_item_from_user_input(turn_context.as_ref(), input).await' in source('core/src/prompt_debug.rs')
assert 'hyotan_lease: self.hyotan_lease.clone()' in source('core/src/session/turn_context.rs')
assert 'capture(&sess.thread_id().to_string(), &review_turn_id)' in source('core/src/session/review.rs')
assert 'self.revoke_hyotan_turn_lease(task.turn_context.as_ref()).await' in source('core/src/tasks/mod.rs')
assert 'self.revoke_hyotan_turn_lease(turn_context.as_ref()).await' in source('core/src/tasks/mod.rs')
assert 'if turn_context.hyotan_lease.revoke().is_err()' in source('core/src/tasks/mod.rs')
assert 'let _ = lease.revoke()' not in source('core/src/hyotan_turn_lease.rs')
assert 'LeaseGuard(ctx.hyotan_lease.clone())' in source('core/src/tasks/mod.rs')
assert 'turn.hyotan_lease.filesystem()' in source('core/src/tools/handlers/view_image.rs')
assert source('protocol/src/models.rs').count('match reader(&path) {')==2
helper=source('core/src/hyotan_turn_lease.rs')
assert 'std::fs::read' not in helper and 'FACTORY.get()' in helper
assert 'lease.matches(&request.thread, &request.turn)' in helper
assert 'sandbox: environment.sandbox_context(None)' in source('core/src/session/turn_context.rs')
assert 'current_submission_admission()' in source('app-server/src/message_processor.rs')
assert 'matches!(&codex_request, ClientRequest::TurnStart { .. })' in source('app-server/src/message_processor.rs')
print('PASS pinned turn/media generation twice; identical hashes and explicit context connections')
for path,digest in first.items(): print(digest+' '+path)
print('LIMIT source assertions do not compile Session/lifecycle or verify Apple/AppServer RPC/all model routes')
