#!/usr/bin/env python3
"""Captured model file handlers against the exact Codex pin; no product install.
Run after prepare-codex/prepare-turn-lease. Does not modify admission/session code.
"""
import argparse,pathlib,shutil,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source',type=pathlib.Path,default=ROOT/'Vendor/codex-source');args=parser.parse_args()
SOURCE=args.source.resolve();PIN='3d2ee51ca2d5db578f328aa75e20aa22c0197c9a'
if subprocess.check_output(['git','-C',str(SOURCE),'rev-parse','HEAD'],text=True).strip()!=PIN:raise RuntimeError('Codex pin mismatch')
def original(p):return subprocess.check_output(['git','-C',str(SOURCE),'show',f'{PIN}:{p}'],text=True)
def replace(s,a,b,count=1):
 if s.count(a)!=count:raise RuntimeError('Unexpected model handler pin anchor '+a[:80])
 return s.replace(a,b)
def put(p,s):
 (SOURCE/p).parent.mkdir(parents=True,exist_ok=True)
 (SOURCE/p).write_text('// Hyotan: captured model file operations preparation.\n'+s)
shutil.copyfile(ROOT/'NativeCodex/ios/model_operations.rs',SOURCE/'codex-rs/core/src/hyotan_model_operations.rs')
p=SOURCE/'codex-rs/core/src/lib.rs';s=p.read_text();hook='\npub mod hyotan_model_operations;\n';p.write_text(s.removesuffix(hook)+hook)

p='codex-rs/core/src/tools/handlers/apply_patch.rs';s=original(p)
s=replace(s,'        let fs = turn_environment.environment.get_filesystem();\n        let sandbox = turn_environment.sandbox_context(/*additional_permissions*/ None);','''        let fs = crate::hyotan_model_operations::filesystem(&turn.hyotan_lease, turn_environment.environment.get_filesystem())
            .map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;
        let sandbox = if crate::hyotan_model_operations::protected(&turn.hyotan_lease) {
            let permissions = apply_granted_turn_permissions(session.as_ref(), turn_environment, turn_environment.cwd(),
                crate::sandboxing::SandboxPermissions::UseDefault, None).await;
            turn_environment.sandbox_context(permissions.additional_permissions)
        } else { turn_environment.sandbox_context(None) };''')
s=replace(s,'''    let turn = &step_context.turn;
    let sandbox = turn_environment.sandbox_context(/*additional_permissions*/ None);''','''    let turn = &step_context.turn;
    turn.hyotan_lease.check().map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;
    let scoped = turn.hyotan_lease.filesystem().map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;
    let fs = scoped.as_deref().unwrap_or(fs);
    let sandbox = if crate::hyotan_model_operations::protected(&turn.hyotan_lease) {
        let permissions = apply_granted_turn_permissions(session.as_ref(), &turn_environment, cwd,
            crate::sandboxing::SandboxPermissions::UseDefault, None).await;
        turn_environment.sandbox_context(permissions.additional_permissions)
    } else { turn_environment.sandbox_context(None) };''')
s=replace(s,'''        effective_patch_permissions(tool_ctx.session.as_ref(), &turn_environment, &action, cwd)
            .await
            .unwrap_or_else(|_| patch_permissions_without_path_matching(&action));''','''        match effective_patch_permissions(tool_ctx.session.as_ref(), &turn_environment, &action, cwd).await {
            Ok(permissions) => permissions,
            Err(_) if crate::hyotan_model_operations::protected(&tool_ctx.step_context.turn.hyotan_lease) =>
                return Err(FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned())),
            Err(_) => patch_permissions_without_path_matching(&action),
        };
    tool_ctx.step_context.turn.hyotan_lease.check()
        .map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;''')
# Correctness errors may contain backend path/details; protected results stay fixed.
s=replace(s,'''"apply_patch verification failed: {parse_error}"
                )))''','''"apply_patch verification failed: {parse_error}"
                ))))''',2)
s=s.replace('''Err(FunctionCallError::RespondToModel(format!(
                    "apply_patch verification failed: {parse_error}"''','''Err(FunctionCallError::RespondToModel(turn.hyotan_lease.sanitize(format!(
                    "apply_patch verification failed: {parse_error}"''')
# The intercepted branch has distinct indentation.
s=replace(s,'''Err(FunctionCallError::RespondToModel(format!(
                "apply_patch verification failed: {parse_error}"
            )))''','''Err(FunctionCallError::RespondToModel(turn.hyotan_lease.sanitize(format!(
                "apply_patch verification failed: {parse_error}"
            ))))''')
put(p,s)

p='codex-rs/core/src/tools/runtimes/apply_patch.rs';s=original(p)
s=replace(s,'        _ctx: &ToolCtx,','        ctx: &ToolCtx,')
s=replace(s,'''        let fs = req.turn_environment.environment.get_filesystem();
        let sandbox = Self::file_system_sandbox_context_for_attempt(req, attempt);''','''        let lease = &ctx.step_context.turn.hyotan_lease;
        let fs = crate::hyotan_model_operations::filesystem(lease, req.turn_environment.environment.get_filesystem())
            .map_err(|_| ToolError::Rejected(hyotan_turn_lease::DENIAL.to_owned()))?;
        let mut sandbox = Self::file_system_sandbox_context_for_attempt(req, attempt);
        // Approval can adjust policy, never bypass the captured capability. An
        // otherwise sandbox-free attempt still carries effective permissions.
        if crate::hyotan_model_operations::protected(lease) && sandbox.is_none() {
            let permissions = effective_permission_profile(attempt.exec_server_permissions,req.additional_permissions.as_ref());
            let mut context = req.turn_environment.sandbox_context(None);
            context.permissions = permissions.into();
            context.cwd = Some(req.action.cwd.clone());
            sandbox = Some(context);
        }
        let sandbox = crate::hyotan_model_operations::sandbox(lease,sandbox)
            .map_err(|_| ToolError::Rejected(hyotan_turn_lease::DENIAL.to_owned()))?;''')
s=replace(s,'                follow_symlinks: attempt.sandbox_requested','                follow_symlinks: !crate::hyotan_model_operations::protected(lease) && (attempt.sandbox_requested')
s=replace(s,'                        attempt.enforce_managed_network,\n                    ),','                        attempt.enforce_managed_network,\n                    )),')
s=replace(s,'''        let stdout = String::from_utf8_lossy(&stdout).into_owned();
        let stderr = String::from_utf8_lossy(&stderr).into_owned();
        let failed = result.is_err();''','''        let stdout = String::from_utf8_lossy(&stdout).into_owned();
        let stderr = String::from_utf8_lossy(&stderr).into_owned();
        let failed = result.is_err() || lease.check().is_err();
        let (stdout,stderr) = if failed && crate::hyotan_model_operations::protected(lease) {
            (String::new(), hyotan_turn_lease::DENIAL.to_owned())
        } else { (stdout,stderr) };''')
put(p,s)

p='codex-rs/core/src/tools/handlers/unified_exec/exec_command.rs';s=original(p)
s=s.replace('FunctionCallError::RespondToModel(err.to_string())','FunctionCallError::RespondToModel(turn.hyotan_lease.sanitize(err.to_string()))')
s=s.replace('.map_err(FunctionCallError::RespondToModel)?;','.map_err(|error| FunctionCallError::RespondToModel(turn.hyotan_lease.sanitize(error)))?;')
s=replace(s,'        let fs = environment.get_filesystem();','''        let fs = crate::hyotan_model_operations::filesystem(&turn.hyotan_lease, environment.get_filesystem())
            .map_err(|_| FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;''')
s=replace(s,'        maybe_emit_implicit_skill_invocation(','        if !crate::hyotan_model_operations::protected(&turn.hyotan_lease) { maybe_emit_implicit_skill_invocation(')
s=replace(s,'        .await;\n        let shell_mode =','        .await; }\n        let shell_mode =')
s=replace(s,'        emit_unified_exec_tty_metric(&turn.session_telemetry, tty);','''        if crate::hyotan_model_operations::native_process(&turn.hyotan_lease).is_err() {
            manager.release_process_id(process_id).await;
            return Err(FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()));
        }
        emit_unified_exec_tty_metric(&turn.session_telemetry, tty);''')
put(p,s)

p='codex-rs/core/src/tools/handlers/extension_tools.rs';s=original(p)
s=replace(s,'self.0.handle(to_extension_call(&invocation).await).await','self.0.handle(to_extension_call(&invocation).await?).await')
s=replace(s,"async fn to_extension_call(invocation: &ToolInvocation) -> ExtensionToolCall<'_> {", "async fn to_extension_call(invocation: &ToolInvocation) -> Result<ExtensionToolCall<'_>, crate::function_tool::FunctionCallError> {\n    invocation.turn.hyotan_lease.check().map_err(|_| crate::function_tool::FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?;")
s=replace(s,'            file_system: environment.environment.get_filesystem(),','''            file_system: crate::hyotan_model_operations::filesystem(&invocation.turn.hyotan_lease, environment.environment.get_filesystem())
                .map_err(|_| crate::function_tool::FunctionCallError::RespondToModel(hyotan_turn_lease::DENIAL.to_owned()))?,''')
s=replace(s,'    ExtensionToolCall {\n        turn_id:','    Ok(ExtensionToolCall {\n        turn_id:')
s=replace(s,'        payload: invocation.payload.clone(),\n    }\n}','        payload: invocation.payload.clone(),\n    })\n}')
put(p,s)
print('Prepared captured apply_patch preflight/runtime, extension filesystem and protected native-exec rejection; legacy route retained.')
