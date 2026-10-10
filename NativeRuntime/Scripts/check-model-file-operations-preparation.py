#!/usr/bin/env python3
"""Pinned model-handler generation and library-profile provenance checks.
Core typecheck/AppServer execution remain separate gates, not source assertions.
"""
import hashlib,json,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1];SOURCE=ROOT/'Vendor/codex-source';PIN='3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'
FILES=['core/src/lib.rs','core/src/hyotan_model_operations.rs','core/src/tools/handlers/apply_patch.rs','core/src/tools/runtimes/apply_patch.rs','core/src/tools/handlers/unified_exec/exec_command.rs','core/src/tools/handlers/extension_tools.rs']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def snapshot():return {n:sha(SOURCE/'codex-rs'/n) for n in FILES}
subprocess.run([sys.executable,ROOT/'Scripts/prepare-codex.py'],check=True);first=snapshot()
subprocess.run([sys.executable,ROOT/'Scripts/prepare-codex.py'],check=True);assert first==snapshot()
text=lambda n:(SOURCE/'codex-rs'/n).read_text()
assert 'filesystem(&turn.hyotan_lease' in text('core/src/tools/handlers/apply_patch.rs')
assert 'scoped.as_deref().unwrap_or(fs)' in text('core/src/tools/handlers/apply_patch.rs')
assert 'Err(_) if crate::hyotan_model_operations::protected' in text('core/src/tools/handlers/apply_patch.rs')
assert 'filesystem(lease, req.turn_environment.environment.get_filesystem())' in text('core/src/tools/runtimes/apply_patch.rs')
assert 'sandbox = Some(context)' in text('core/src/tools/runtimes/apply_patch.rs')
assert 'native_process(&turn.hyotan_lease)' in text('core/src/tools/handlers/unified_exec/exec_command.rs')
assert 'filesystem(&invocation.turn.hyotan_lease' in text('core/src/tools/handlers/extension_tools.rs')
assert 'to_extension_call(&invocation).await?' in text('core/src/tools/handlers/extension_tools.rs')
fixture=ROOT/'ModelFileOperationIntegration';profile=json.loads((fixture/'patch-profile.json').read_text());assert profile['pin']==PIN
for name,expected in profile['sources'].items():
 original=subprocess.check_output(['git','-C',SOURCE,'show',f'{PIN}:codex-rs/apply-patch/src/{name}'])
 assert hashlib.sha256(original).hexdigest()==expected['upstream_sha256']
 content=original.decode()
 if name=='lib.rs':content=content.replace('mod standalone_executable;','#[cfg(feature="unrestricted-standalone")]\nmod standalone_executable;').replace('pub use standalone_executable::main;','#[cfg(feature="unrestricted-standalone")]\npub use standalone_executable::main;')
 actual=(fixture/'patch-engine/src'/name).read_bytes();assert actual==content.encode();assert hashlib.sha256(actual).hexdigest()==expected['profile_sha256']
print('PASS pinned model handler generation twice; exact hashes; actual patch engine source profile verified')
for n,h in first.items():print(h+' '+n)
print('LIMIT source checks do not typecheck Core or execute model/AppServer/iOS handlers; library-source integration test is separate evidence')
