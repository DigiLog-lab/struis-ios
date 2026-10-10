#!/usr/bin/env python3
"""Pinned role snapshots from captured parent capability; run after turn/model preparation.
No installation, authority creation, raw protected read, or product switch.
"""
import argparse, pathlib, subprocess, re
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=pathlib.Path,default=ROOT/'Vendor/codex-source');a=p.parse_args();SOURCE=a.source.resolve()
PIN='3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'
assert subprocess.check_output(['git','-C',SOURCE,'rev-parse','HEAD'],text=True).strip()==PIN
if 'pub mod hyotan_model_operations;' not in (SOURCE/'codex-rs/core/src/lib.rs').read_text() or 'capture_resolved' not in (SOURCE/'codex-rs/core/src/session/turn_context.rs').read_text():
 raise RuntimeError('Run issuer and model preparation before captured role generation')
def original(p):return subprocess.check_output(['git','-C',SOURCE,'show',f'{PIN}:{p}'],text=True)
def replace(s,a,b,n=1):
 if s.count(a)!=n:raise RuntimeError('Unexpected role pin anchor '+a[:90])
 return s.replace(a,b)
def put(p,s):(SOURCE/p).write_text('// Hyotan: captured parent role snapshots preparation.\n'+s)
p='codex-rs/core/src/agent/role.rs';s=original(p)
s=replace(s,'''    let role_name = role_name.unwrap_or(DEFAULT_ROLE_NAME);''','''    apply_role_to_config_captured(config, role_name, &crate::hyotan_turn_lease::CapturedTurnLease::Legacy, None).await
}

pub(crate) async fn apply_role_to_config_captured(
    config: &mut Config, role_name: Option<&str>,
    lease: &crate::hyotan_turn_lease::CapturedTurnLease,
    snapshot: Option<&RoleSnapshot>,
) -> Result<(), String> {
    lease.check().map_err(|_| hyotan_turn_lease::DENIAL.to_owned())?;
    let role_name = role_name.unwrap_or(DEFAULT_ROLE_NAME);''')
s=replace(s,'apply_role_to_config_inner(config, role_name, &role)','apply_role_to_config_inner(config, role_name, &role, lease, snapshot)')
s=replace(s,'            tracing::warn!("failed to apply role to config: {err}");','''            if matches!(lease, crate::hyotan_turn_lease::CapturedTurnLease::Legacy) {
                tracing::warn!("failed to apply role to config: {err}");
            }
            if !matches!(lease, crate::hyotan_turn_lease::CapturedTurnLease::Legacy) {
                return hyotan_turn_lease::DENIAL.to_owned();
            }''')
s=replace(s,'    role: &AgentRoleConfig,\n) -> anyhow::Result<()> {','''    role: &AgentRoleConfig,
    lease: &crate::hyotan_turn_lease::CapturedTurnLease,
    snapshot: Option<&RoleSnapshot>,
) -> anyhow::Result<()> {''')
s=replace(s,'    let role_layer_toml = load_role_layer_toml(config, config_file, is_built_in, role_name).await?;','''    let role_layer_toml = if matches!(lease, crate::hyotan_turn_lease::CapturedTurnLease::Legacy) || is_built_in {
        load_role_layer_toml(config, config_file, is_built_in, role_name).await?
    } else {
        snapshot.ok_or_else(hyotan_turn_lease::denied)?.layer(role_name, config_file)?.clone()
    };
    lease.check()?;''')
s=replace(s,'    *config = role_overrides::build_next_config(config, role_layer_toml, &overrides)?;', '    lease.check()?;\n    *config = role_overrides::build_next_config(config, role_layer_toml, &overrides)?;')
# Preserve the existing legacy API; protected descriptions consume the same parsed
# immutable layer as actual role application, never filesystem paths.
s=replace(s,'        build_from_configs(built_in_roles, user_defined_agent_roles)','        build_from_configs(built_in_roles, user_defined_agent_roles, None)')
s=replace(s,'    // This function is not inlined for testing purpose.','''    pub(crate) fn build_captured(
        roles: &BTreeMap<String, AgentRoleConfig>,
        lease: &crate::hyotan_turn_lease::CapturedTurnLease,
        snapshot: Option<&RoleSnapshot>,
    ) -> String {
        if matches!(lease, crate::hyotan_turn_lease::CapturedTurnLease::Legacy) { return build(roles); }
        if lease.check().is_err() { return hyotan_turn_lease::DENIAL.to_owned(); }
        match snapshot {
            Some(snapshot) => build_from_configs(built_in::configs(), roles, Some(snapshot)),
            None => hyotan_turn_lease::DENIAL.to_owned(),
        }
    }

    // This function is not inlined for testing purpose.''')
s=replace(s,'        user_defined_roles: &BTreeMap<String, AgentRoleConfig>,\n    ) -> String {','        user_defined_roles: &BTreeMap<String, AgentRoleConfig>,\n        snapshot: Option<&RoleSnapshot>,\n    ) -> String {')
# Distinct loops preserve shadowing and embedded-only built-in descriptions.
s=replace(s,'''                formatted_roles.push(format_role(name, declaration));
            }
        }
        for (name, declaration) in built_in_roles''','''                formatted_roles.push(format_role(name, declaration, snapshot, true));
            }
        }
        for (name, declaration) in built_in_roles''')
s=replace(s,'format_role(name, declaration)', 'format_role(name, declaration, snapshot, false)')
s=replace(s,'    fn format_role(name: &str, declaration: &AgentRoleConfig) -> String {','''    fn format_role(name: &str, declaration: &AgentRoleConfig, snapshot: Option<&RoleSnapshot>, custom: bool) -> String {
        if let (Some(snapshot), Some(path)) = (snapshot, declaration.config_file.as_ref()) {
            if custom && snapshot.layer(name, path).is_err() {
                return format!("{name}: {}", hyotan_turn_lease::DENIAL);
            }
        }''')
s=replace(s,'''                    built_in::config_file_contents(config_file)
                        .map(str::to_owned)
                        .or_else(|| std::fs::read_to_string(config_file).ok())
                })
                .and_then(|contents| toml::from_str::<TomlValue>(&contents).ok())''','''                    if let Some(snapshot) = snapshot {
                        // User roles shadow built-ins, even when their pathname is
                        // identical to an embedded role's basename.
                        if custom {
                            return snapshot.layer(name, config_file).ok().cloned();
                        }
                        return built_in::config_file_contents(config_file)
                            .and_then(|contents| toml::from_str::<TomlValue>(contents).ok());
                    }
                    built_in::config_file_contents(config_file).map(str::to_owned)
                        .or_else(|| std::fs::read_to_string(config_file).ok())
                        .and_then(|contents| toml::from_str::<TomlValue>(&contents).ok())
                })''')
s+='\n'+(ROOT/'NativeCodex/ios/role_snapshot.rs').read_text()+'\n'+(ROOT/'NativeCodex/ios/role_snapshot_tests.rs').read_text();put(p,s)
# Layer onto issuer-generated contexts, never recreate admission/capture code.
p='codex-rs/core/src/session/turn_context.rs';s=(SOURCE/p).read_text()
# Remove our exact additions for idempotence while retaining prerequisite edits.
field='    pub(crate) hyotan_roles: std::sync::Arc<tokio::sync::OnceCell<crate::agent::role::RoleSnapshot>>,\n'
clone='            hyotan_roles: self.hyotan_roles.clone(),\n'
init='            hyotan_roles: std::sync::Arc::new(tokio::sync::OnceCell::new()),\n'
s=s.replace(field,'').replace(clone,'').replace(init,'')
s=re.sub(r'(pub struct TurnContext \{\n)\n+',r'\1',s)
s=replace(s,'pub struct TurnContext {\n','pub struct TurnContext {\n'+field)
s=replace(s,'            sub_id: self.sub_id.clone(),',clone+'            sub_id: self.sub_id.clone(),')
s=replace(s,'        TurnContext {\n','        TurnContext {\n'+init);(SOURCE/p).write_text(s)
p='codex-rs/core/src/session/review.rs';s=(SOURCE/p).read_text();init='        hyotan_roles: std::sync::Arc::new(tokio::sync::OnceCell::new()),\n';s=s.replace(init,'');s=re.sub(r'(    let review_turn_context = TurnContext \{\n)\n+',r'\1',s);s=replace(s,'    let review_turn_context = TurnContext {\n','    let review_turn_context = TurnContext {\n'+init);(SOURCE/p).write_text(s)
p='codex-rs/core/src/session/turn.rs';s=(SOURCE/p).read_text();hook='    crate::agent::role::prepare_roles(turn_context).await;\n';s=s.replace(hook,'');s=replace(s,'    Ok(Arc::new(build_tool_router(',hook+'    Ok(Arc::new(build_tool_router(');(SOURCE/p).write_text(s)
p='codex-rs/core/src/tools/spec_plan.rs';s=original(p);s=replace(s,'crate::agent::role::spawn_tool_spec::build(&turn_context.config.agent_roles)','crate::agent::role::spawn_tool_spec::build_captured(&turn_context.config.agent_roles, &turn_context.hyotan_lease, turn_context.hyotan_roles.get())');put(p,s)
p='codex-rs/core/src/tools/handlers/multi_agents_common.rs';s=original(p);s=replace(s,'''pub(crate) async fn apply_spawn_agent_role(
    session: &Session,
    config: &mut Config,''','''pub(crate) async fn apply_spawn_agent_role(
    session: &Session,
    turn: &crate::TurnContext,
    config: &mut Config,''')
s=replace(s,'    apply_role_to_config(config, role_name)','''    let snapshot = crate::agent::role::prepare_roles(turn).await;
    crate::agent::role::apply_role_to_config_captured(config, role_name, &turn.hyotan_lease, Some(snapshot))''')
s=s.replace('use crate::agent::role::apply_role_to_config;\n','');put(p,s)
for p in ['codex-rs/core/src/tools/handlers/multi_agents/spawn.rs','codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs']:
 s=original(p);s=replace(s,'apply_spawn_agent_role(&session, &mut config, role_name)','apply_spawn_agent_role(&session, turn.as_ref(), &mut config, role_name)');put(p,s)
p='codex-rs/core/Cargo.toml';s=(SOURCE/p).read_text()
for dep in ['hyotan-operation-harness = { path = \"../../../../OperationHarness\" }\n', 'hyotan-appserver-operation-harness = { path = \"../../../../AppServerOperationHarness\" }\n']:
 s=s.replace(dep,'');s=replace(s,'[dev-dependencies]\n','[dev-dependencies]\n'+dep)
(SOURCE/p).write_text(s)
# Only local dev dependency edges are added to the existing composed lock.
p='codex-rs/Cargo.lock';s=(SOURCE/p).read_text();start=s.index('[[package]]\nname = \"codex-core\"\n');end=s.index('[[package]]',start+12);section=s[start:end]
for name in ['hyotan-appserver-operation-harness','hyotan-operation-harness']:
 line=' \"'+name+'\",\n';section=section.replace(line,'');section=replace(section,' \"hyotan-turn-lease\",\n',line+' \"hyotan-turn-lease\",\n')
(SOURCE/p).write_text(s[:start]+section+s[end:])
print('Prepared captured parent immutable role layers and exact descriptions; legacy routes preserved.')
