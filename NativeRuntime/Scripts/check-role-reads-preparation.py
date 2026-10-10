#!/usr/bin/env python3
"""Role generation determinism and concrete call-site manifest; no runtime claim."""
import hashlib,json,pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parents[1];SOURCE=ROOT/'Vendor/codex-source'
FILES=['Cargo.lock','core/Cargo.toml','core/src/agent/role.rs','core/src/session/turn_context.rs','core/src/session/review.rs','core/src/session/turn.rs','core/src/tools/spec_plan.rs','core/src/tools/handlers/multi_agents_common.rs','core/src/tools/handlers/multi_agents/spawn.rs','core/src/tools/handlers/multi_agents_v2/spawn.rs']
def snapshot():return {name:hashlib.sha256((SOURCE/'codex-rs'/name).read_bytes()).hexdigest() for name in FILES}
subprocess.run([sys.executable,ROOT/'Scripts/prepare-role-reads.py'],check=True);first=snapshot()
subprocess.run([sys.executable,ROOT/'Scripts/prepare-role-reads.py'],check=True);assert first==snapshot()
def text(p):return (SOURCE/'codex-rs'/p).read_text()
assert 'prepare_roles(turn_context).await' in text('core/src/session/turn.rs')
assert 'spawn_tool_spec::build_captured' in text('core/src/tools/spec_plan.rs')
assert 'apply_role_to_config_captured(config, role_name, &turn.hyotan_lease' in text('core/src/tools/handlers/multi_agents_common.rs')
for p in FILES[-2:]:assert 'apply_spawn_agent_role(&session, turn.as_ref(),' in text(p)
assert 'hyotan_roles: self.hyotan_roles.clone()' in text('core/src/session/turn_context.rs')
assert 'snapshot.ok_or_else(hyotan_turn_lease::denied)?.layer(role_name, config_file)?.clone()' in text('core/src/agent/role.rs')
assert 'captured_role_layer(&CapturedTurnLease::Denied' in text('core/src/agent/role.rs')
print('PASS role generator idempotence and exact v1/v2/spec/async-preload call-site anchors')
print(json.dumps(first,indent=2));print('LIMIT source assertions do not execute role tests, Core, AppServer RPC, or Apple; no product installation')
