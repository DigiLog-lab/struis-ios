#!/usr/bin/env python3
"""Captured host skill preparation against exact Codex pin; no product installation.
Run after turn/model/role preparations. Workspace discovery never uses service cache.
"""
import pathlib,shutil,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1];SOURCE=ROOT/'Vendor/codex-source'
PIN='3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'
if subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'],text=True).strip()!=PIN:raise RuntimeError('Codex pin mismatch')
def original(p):return subprocess.check_output(['git','-C',str(SOURCE),'show',f'{PIN}:{p}'],text=True)
def replace(s,a,b):
 if s.count(a)!=1:raise RuntimeError('Unexpected host skills pin anchor '+a[:100])
 return s.replace(a,b)
def put(p,s):(SOURCE/p).write_text('// Hyotan: captured host skill preparation.\n'+s)
shutil.copyfile(ROOT/'NativeCodex/ios/skill_filesystem.rs',SOURCE/'codex-rs/ext/skills/src/hyotan_skill_filesystem.rs')
p='codex-rs/ext/skills/src/lib.rs';s=original(p);put(p,s+'\npub mod hyotan_skill_filesystem;\n')
p='codex-rs/skills/src/lib.rs';s=original(p);s+='''
/// Trusted immutable ingress: exact bundled bytes, never the materialized disk cache.
pub fn hyotan_embedded_skill_files() -> Vec<(std::path::PathBuf, &'static [u8])> {
    fn collect(dir: &'static Dir<'static>, result: &mut Vec<(std::path::PathBuf, &'static [u8])>) {
        for entry in dir.entries() { match entry {
            include_dir::DirEntry::Dir(child) => collect(child, result),
            include_dir::DirEntry::File(file) => result.push((file.path().to_path_buf(), file.contents())),
        } }
    }
    let mut result = Vec::new(); collect(&SYSTEM_SKILLS_DIR, &mut result); result
}
''';put(p,s)
p='codex-rs/ext/skills/src/host_snapshot.rs';s=original(p)
s=replace(s,'    outcome: Arc<SkillLoadOutcome>,','    outcome: Arc<SkillLoadOutcome>,\n    check: Option<crate::hyotan_skill_filesystem::Check>,')
s=replace(s,'#[derive(Debug, Clone)]','#[derive(Clone)]')
s=replace(s,'        Self { outcome }','        Self { outcome, check: None }')
s=replace(s,'    pub fn outcome(&self)','''    pub fn protected_empty(check: crate::hyotan_skill_filesystem::Check) -> Self {
        Self { outcome: Arc::new(SkillLoadOutcome::default()), check: Some(check) }
    }
    pub fn check(&self) -> io::Result<()> {
        self.check.as_ref().map_or(Ok(()), |check| check().map_err(|_| crate::hyotan_skill_filesystem::denied()))
    }
    pub fn protected(&self) -> bool { self.check.is_some() }
    pub fn sanitize_error(&self, legacy: String) -> String {
        if self.protected() { crate::hyotan_skill_filesystem::DENIAL.to_owned() } else { legacy }
    }
    pub(crate) fn captured(outcome: SkillLoadOutcome, check: crate::hyotan_skill_filesystem::Check) -> Self {
        Self { outcome: Arc::new(outcome), check: Some(check) }
    }
    pub fn outcome(&self)''')
s=replace(s,'        self.outcome.read_skill_text(skill).await','''        self.check()?;
        if self.protected() && !self.outcome.skills.iter().any(|loaded| loaded == skill) {
            return Err(crate::hyotan_skill_filesystem::denied());
        }
        let result = if self.protected() {
            let fs = self.outcome.file_system_for_skill(skill).ok_or_else(crate::hyotan_skill_filesystem::denied)?;
            let path = codex_utils_path_uri::PathUri::from_abs_path(&skill.path_to_skills_md);
            fs.read_file_text(&path, codex_exec_server::ReadFileOptions::default(), None).await
                .map_err(|_| crate::hyotan_skill_filesystem::denied())
        } else { self.outcome.read_skill_text(skill).await };
        self.check()?;
        result''')
s+='''
impl std::fmt::Debug for HostSkillsSnapshot {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HostSkillsSnapshot").field("outcome", &self.outcome).field("protected", &self.protected()).finish()
    }
}
''';put(p,s)
p='codex-rs/ext/skills/src/host_service.rs';s=original(p)
s=replace(s,'    pub fn clear_cache(&self) {','''    /// A request-local protected snapshot. No service/global/request cache or
    /// preloaded plugin filesystem is reused across captured generations.
    pub async fn snapshot_for_captured_turn(
        &self, input: &HostSkillsLoadInput, filesystem: Arc<dyn ExecutorFileSystem>,
        sandbox: codex_exec_server::FileSystemSandboxContext, check: crate::hyotan_skill_filesystem::Check,
    ) -> std::io::Result<HostSkillsSnapshot> {
        check().map_err(|_| crate::hyotan_skill_filesystem::denied())?;
        let workspace = crate::hyotan_skill_filesystem::SkillFileSystem::workspace(filesystem, sandbox, check.clone());
        let mut roots = resolve_skill_roots(Some(workspace.clone()), &input.config_layer_stack,
            &input.cwd, input.effective_skill_roots.clone(), self.extra_roots()).await;
        // Classification comes from trusted service construction. Even user,
        // admin and plugin roots receive workspace authority, never LOCAL_FS.
        roots.retain(|root| root.scope != SkillScope::System);
        for root in &mut roots { root.file_system = workspace.clone(); }
        if bundled_skills_enabled_from_stack(&input.config_layer_stack) {
            let root = codex_skills::system_cache_root_dir(&self.codex_home);
            roots.push(HostSkillRoot::host(root.clone(), SkillScope::System,
                crate::hyotan_skill_filesystem::SkillFileSystem::embedded(&root, check.clone())));
        }
        let mut outcome = load_and_merge_host_skill_roots_with_request_snapshots(
            roots, &self.root_scan_slots, self.restriction_product, None, None).await;
        // The legacy implicit lookup canonicalizes via native pathname APIs.
        // Protected identities are already resolved through the captured source;
        // do not invoke that unscoped compatibility projection.
        outcome.disabled_paths = skill_config_rules_from_stack(&input.config_layer_stack)
            .resolve_disabled_paths(outcome.skills.iter().map(|skill| (skill.name.as_str(), &skill.path_to_skills_md)));
        for skill in outcome.skills.iter().filter(|skill| !outcome.disabled_paths.contains(&skill.path_to_skills_md)) {
            Arc::make_mut(&mut outcome.implicit_skills_by_doc_path).insert(skill.path_to_skills_md.clone(), skill.clone());
            if let Some(parent) = skill.path_to_skills_md.parent() {
                Arc::make_mut(&mut outcome.implicit_skills_by_scripts_dir).insert(parent.join("scripts"), skill.clone());
            }
        }
        for error in &mut outcome.errors {
            error.path = AbsolutePathBuf::from_absolute_path(std::path::PathBuf::from("/__hyotan_denied_skill__")).expect("fixed absolute diagnostic");
            error.message = crate::hyotan_skill_filesystem::DENIAL.to_owned();
        }
        check().map_err(|_| crate::hyotan_skill_filesystem::denied())?;
        Ok(HostSkillsSnapshot::captured(outcome, check))
    }

    pub fn clear_cache(&self) {''');put(p,s)
p='codex-rs/ext/skills/src/host_prompt.rs';s=original(p)
s=replace(s,'        for skill in selected_skills {','''        if self.check().is_err() {
            prompts.warnings.push(crate::hyotan_skill_filesystem::DENIAL.to_owned());
            return prompts;
        }
        for skill in selected_skills {''')
s=replace(s,'''                    prompts.warnings.push(format!(
                        "Failed to load skill {} at {}: {err:#}",
                        skill.name,
                        skill.path_to_skills_md.display()
                    ));''','''                    prompts.warnings.push(self.sanitize_error(format!(
                        "Failed to load skill {} at {}: {err:#}",
                        skill.name,
                        skill.path_to_skills_md.display()
                    )));''')
s=replace(s,'        prompts\n    }','''        if self.check().is_err() {
            prompts.fragments.clear(); prompts.injected.clear(); prompts.warnings.clear();
            prompts.warnings.push(crate::hyotan_skill_filesystem::DENIAL.to_owned());
        }
        prompts
    }''');put(p,s)
p='codex-rs/ext/skills/src/provider/host.rs';s=original(p)
s=s.replace('''            Ok(catalog_from_outcome(host_snapshot.outcome()))''','''            host_snapshot.check().map_err(|_| SkillProviderError::new(crate::hyotan_skill_filesystem::DENIAL))?;
            Ok(catalog_from_outcome(host_snapshot.outcome()))''')
s=replace(s,'            let Some(skill) = host_snapshot.outcome().skills.iter().find(|skill| {','''            host_snapshot.check().map_err(|_| SkillProviderError::new(crate::hyotan_skill_filesystem::DENIAL))?;
            let Some(skill) = host_snapshot.outcome().skills.iter().find(|skill| {''')
s=replace(s,'''SkillProviderError::new(format!(
                    "host skill resource is not loaded: {}",
                    request.resource.as_str()
                ))''','''SkillProviderError::new(host_snapshot.sanitize_error(format!(
                    "host skill resource is not loaded: {}",
                    request.resource.as_str()
                )))''')
s=replace(s,'''SkillProviderError::new(format!(
                    "failed to read host skill resource {}: {err}",
                    request.resource.as_str()
                ))''','''SkillProviderError::new(host_snapshot.sanitize_error(format!(
                    "failed to read host skill resource {}: {err}",
                    request.resource.as_str()
                )))''');put(p,s)
# This file composes turn + role preparation rather than restarting from pin.
p='codex-rs/core/src/session/turn_context.rs';s=(SOURCE/p).read_text()
# Normalize our own two additions before reapplying to retain idempotence.
start=s.find('        // Hyotan captured skill snapshot starts here.\n')
if start!=-1:
 end=s.index('        // Hyotan captured skill snapshot ends here.\n',start)+len('        // Hyotan captured skill snapshot ends here.\n')
 block=s[start:end]
 legacy_start=block.index('        let skills_snapshot = if turn_context.config\n')
 legacy_end=block.index('            skills_snapshot\n        } else {',legacy_start)
 restored=block[legacy_start:legacy_end].replace('turn_context.config','per_turn_config').replace('turn_context.environments.primary()','primary_turn_environment')
 s=s[:start]+s[end:]
 index=s.rindex('        let step_settings = Arc::new(')
 s=s[:index]+restored+s[index:]
 s=replace(s,'            HostSkillsSnapshot::new(Arc::new(SkillLoadOutcome::default())),\n        );','            skills_snapshot,\n        );')
start=s.index('        let skills_snapshot = if per_turn_config\n')
end=s.index('        let step_settings = Arc::new(',start)
legacy=s[start:end].rstrip()+'\n'
s=s[:start]+s[end:]
s=replace(s,'            skills_snapshot,\n        );','''            HostSkillsSnapshot::new(Arc::new(SkillLoadOutcome::default())),
        );''')
legacy=legacy.replace('per_turn_config','turn_context.config').replace('primary_turn_environment','turn_context.environments.primary()')
# Existing source retained for uninstalled legacy; protected service path added.
protected='''        // Hyotan captured skill snapshot starts here.
        // If this added preparation future is dropped/panics while awaiting
        // discovery, revoke the captured authority; existing counter records failure.
        let mut skill_preparation_guard = crate::hyotan_turn_lease::LeaseGuard(turn_context.hyotan_lease.clone());
        let skills_snapshot = if matches!(&turn_context.hyotan_lease, crate::hyotan_turn_lease::CapturedTurnLease::Legacy) {
LEGACY
            skills_snapshot
        } else {
            let lease = turn_context.hyotan_lease.clone();
            let check: codex_skills_extension::hyotan_skill_filesystem::Check = Arc::new(move || lease.check());
            let result = if turn_context.config.features.enabled(Feature::SkipHostSkillDiscovery)
                && !self.services.extensions.requires_host_skill_discovery() {
                check().map(|_| HostSkillsSnapshot::protected_empty(check.clone()))
            } else { match (turn_context.hyotan_lease.filesystem(), turn_context.environments.primary()) {
                (Ok(Some(fs)), Some(environment)) => {
                    let input = skills_load_input_from_config(&turn_context.config, plugin_outcome.effective_plugin_skill_roots());
                    self.services.skills_service.snapshot_for_captured_turn(&input, fs, environment.sandbox_context(None), check.clone()).await
                }
                _ => Err(hyotan_turn_lease::denied()),
            } };
            result.unwrap_or_else(|_| HostSkillsSnapshot::protected_empty(check))
        };
        turn_context.extension_data.insert(skills_snapshot);
        skill_preparation_guard.0 = crate::hyotan_turn_lease::CapturedTurnLease::Legacy;
        // Hyotan captured skill snapshot ends here.
'''.replace('LEGACY',legacy)
s=replace(s,'        turn_context.code_mode_available = self.services.code_mode_service.is_available();',protected+'        turn_context.code_mode_available = self.services.code_mode_service.is_available();')
# The original legacy block is nested only once; subsequent standalone calls
# require preceding turn/role regeneration, as does the standard composition.
(SOURCE/p).write_text(s)
# Workspace capabilities refuse to follow directory symlinks, so a walk that asks to follow
# them is denied outright and repo/user skills were never discovered (2026-10-04, Struis
# struis-document skill). Discovery walks without following directory symlinks for every scope.
p='codex-rs/ext/skills/src/loader/host.rs';s=original(p)
s=replace(s,'''        SkillScope::User | SkillScope::Repo | SkillScope::Admin => DirectorySymlinkPolicy::Follow,
        SkillScope::System => DirectorySymlinkPolicy::Ignore,''','''        SkillScope::User | SkillScope::Repo | SkillScope::Admin | SkillScope::System => DirectorySymlinkPolicy::Ignore,''');put(p,s)
print('Prepared captured host skill discovery/prompt/provider reads; immutable embedded ingress; no product install.')

# Dedicated existing filtered process: real MessageProcessor + actual providers.
shutil.copyfile(ROOT/'NativeCodex/ios/host_skill_appserver_tests.rs', SOURCE/'codex-rs/app-server/src/message_processor_tracing_tests/hyotan_host_skill_tests.rs')
p='codex-rs/app-server/src/message_processor_tracing_tests/hyotan_captured_turn_tests.rs'
s=(ROOT/'NativeCodex/ios/turn_lease_appserver_tests.rs').read_text()
s=replace(s,'    block_read: AtomicBool,','    block_read: AtomicBool,\n    block_path: std::path::PathBuf,')
s=replace(s,'            if self.block_read.swap(false, Ordering::AcqRel) {','            if path.to_abs_path().is_ok_and(|path| path.as_path() == self.block_path) && self.block_read.swap(false, Ordering::AcqRel) {')
s=replace(s,'                block_read: AtomicBool::new(permit.block),','                block_read: AtomicBool::new(permit.block),\n                block_path: captured_issuer.root.join("日本語.png"),')
s=replace(s,'''                        vec![UserInput::LocalAudio {
                            path: issuer.root.join("日本語.wav"),
                        }]''','''                        vec![UserInput::LocalAudio {
                            path: issuer.root.join("日本語.wav"),
                        }, UserInput::Skill { name: "authorized-host-skill".into(), path: issuer.root.join(".agents/skills/authorized/SKILL.md") }]''')
s=replace(s,'        let issuer = Arc::new(Issuer {','''        captured_host_skill_sources(&root, &private).await?;
        let skill = root.join(".agents/skills/authorized/SKILL.md");
        std::fs::create_dir_all(skill.parent().unwrap())?;
        std::fs::write(&skill,"---\nname: authorized-host-skill\ndescription: authorized actual RPC skill\n---\nACTUAL_RPC_SKILL_BYTES")?;
        let issuer = Arc::new(Issuer {''')
s=replace(s,'        let authorized_requests = request_mock.requests();','''        let authorized_requests = request_mock.requests();
        assert!(authorized_requests.iter().any(|request| request.body_json().to_string().contains("ACTUAL_RPC_SKILL_BYTES")), "actual MessageProcessor turn must inject authorized captured skill bytes");''')
s+='\ninclude!("hyotan_host_skill_tests.rs");\n'
put(p,s)
