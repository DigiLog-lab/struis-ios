//! Model-operation routing for the captured turn authority. No new grant issuer.
use crate::hyotan_turn_lease::CapturedTurnLease;
use codex_file_system::{ExecutorFileSystem,FileSystemSandboxContext};
use std::{io,sync::Arc};

pub fn protected(lease: &CapturedTurnLease) -> bool {
    !matches!(lease,CapturedTurnLease::Legacy)
}
/// Only absence of a trusted installation preserves the legacy environment.
/// A denied/revoked installed lease never falls back to native filesystem I/O.
pub fn filesystem(lease: &CapturedTurnLease, legacy: Arc<dyn ExecutorFileSystem>) -> io::Result<Arc<dyn ExecutorFileSystem>> {
    lease.check()?;
    match lease.filesystem()? {Some(fs)=>Ok(fs),None=>Ok(legacy)}
}
/// A scoped filesystem is an additional boundary, not permission escalation.
/// Protected operations must also carry their effective environment permissions.
pub fn sandbox(lease: &CapturedTurnLease, context: Option<FileSystemSandboxContext>) -> io::Result<Option<FileSystemSandboxContext>> {
    lease.check()?;
    if protected(lease) && context.is_none() {return Err(hyotan_turn_lease::denied());}
    Ok(context)
}
/// Native process execution is not mediated by ExecutorFileSystem. Until a real
/// captured process/provider exists, installed protected turns refuse that route.
pub fn native_process(lease: &CapturedTurnLease) -> io::Result<()> {
    lease.check()?;
    if protected(lease) {Err(hyotan_turn_lease::denied())} else {Ok(())}
}
