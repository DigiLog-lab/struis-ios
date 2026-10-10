//! Preparation only: trusted embedding must install before creating contexts.
//! The factory binds exact thread/turn; absence while protected fails closed.
use codex_file_system::ExecutorFileSystem;
pub use hyotan_turn_lease::Identity;
use hyotan_turn_lease::{CapturedLease, denied};
use std::io;
use std::sync::{
    Arc, OnceLock,
    atomic::{AtomicU64, Ordering},
};
pub type TurnLease = CapturedLease<dyn ExecutorFileSystem>;
/// Cloned from the actual ready Session environment. The cwd is policy context,
/// never authority to open a directory. The trusted issuer owns the FD/grant.
pub struct CaptureRequest {
    pub thread: String,
    pub turn: String,
    pub sandbox: codex_file_system::FileSystemSandboxContext,
    pub environment_id: String,
    pub session_source: codex_protocol::protocol::SessionSource,
    pub parent_thread: Option<String>,
}
pub type Factory = dyn Fn(&CaptureRequest) -> io::Result<Arc<TurnLease>> + Send + Sync;
// Monotonic trusted diagnostic: even a Drop-only failure is observable. No
// path, error payload, credentials or model-controlled diagnostic is retained.
static CLEANUP_FAILURES: AtomicU64 = AtomicU64::new(0);
pub fn cleanup_failure_count() -> u64 {
    CLEANUP_FAILURES.load(Ordering::Acquire)
}
fn revoke_bound(lease: &TurnLease) -> io::Result<()> {
    lease.revoke().map_err(|_| {
        match CLEANUP_FAILURES.fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
            Some(value.saturating_add(1))
        }) {
            Ok(_) | Err(_) => (),
        }
        denied()
    })
}
static FACTORY: OnceLock<Arc<Factory>> = OnceLock::new();
/// Trusted Rust embedding only. No RPC/model/environment grants are introduced.
pub fn install(factory: Arc<Factory>) -> Result<(), Arc<Factory>> {
    FACTORY.set(factory)
}
#[derive(Clone)]
pub enum CapturedTurnLease {
    Legacy,
    Denied,
    Bound(Arc<TurnLease>),
}
impl CapturedTurnLease {
    /// Unresolved/review construction never guesses a protected grant.
    pub fn capture(_thread: &str, _turn: &str) -> Self {
        if FACTORY.get().is_none() {
            Self::Legacy
        } else {
            Self::Denied
        }
    }
    pub fn capture_resolved(request: Option<CaptureRequest>) -> Self {
        match FACTORY.get() {
            None => Self::Legacy,
            Some(factory) => {
                let Some(request) = request else {
                    return Self::Denied;
                };
                match factory(&request) {
                    Ok(lease)
                        if lease.matches(&request.thread, &request.turn)
                            && lease.check().is_ok() =>
                    {
                        Self::Bound(lease)
                    }
                    Ok(lease) => {
                        if revoke_bound(&lease).is_err() {
                            return Self::Denied;
                        }
                        Self::Denied
                    }
                    Err(_) => Self::Denied,
                }
            }
        }
    }
    pub fn check(&self) -> io::Result<()> {
        match self {
            Self::Legacy => Ok(()),
            Self::Denied => Err(denied()),
            Self::Bound(lease) => lease.check(),
        }
    }
    pub fn filesystem(&self) -> io::Result<Option<Arc<dyn ExecutorFileSystem>>> {
        match self {
            Self::Legacy => Ok(None),
            Self::Denied => Err(denied()),
            Self::Bound(lease) => lease.authority().map(Some),
        }
    }
    /// Success confirms the underlying grant has been invalidated. Failure is
    /// sanitized, recorded, and must prevent a successful terminal acknowledgement.
    pub fn revoke(&self) -> io::Result<()> {
        match self {
            Self::Bound(lease) => revoke_bound(lease),
            _ => Ok(()),
        }
    }
}
impl CapturedTurnLease {
    pub fn sanitize(&self, legacy: String) -> String {
        if matches!(self, Self::Legacy) {
            legacy
        } else {
            hyotan_turn_lease::DENIAL.to_owned()
        }
    }
}
pub(crate) struct LeaseGuard(pub CapturedTurnLease);
impl Drop for LeaseGuard {
    fn drop(&mut self) {
        // No async RPC can be emitted in Drop. revoke_bound records the failed
        // cleanup for trusted diagnostics; explicit Session paths report Error.
        match self.0.revoke() {
            Ok(()) => (),
            Err(_) => (),
        }
    }
}

/// LocalMedia input is a pathname request, never an authority. Trusted ingress
/// must stage/authorize attachments before giving them to a protected turn.
pub async fn prepare_local_media(
    lease: &CapturedTurnLease,
    input: Vec<codex_protocol::user_input::UserInput>,
) -> codex_protocol::models::ResponseInputItem {
    use codex_protocol::models::{LocalImagePreparation, ResponseInputItem};
    use codex_protocol::user_input::UserInput;
    match lease.filesystem() {
        Ok(None) => ResponseInputItem::from_user_input(input, LocalImagePreparation::Defer),
        scoped => {
            let mut reads = std::collections::VecDeque::new();
            for entry in &input {
                let path = match entry {
                    UserInput::LocalImage { path, .. } | UserInput::LocalAudio { path } => path,
                    _ => continue,
                };
                let result = match &scoped {
                    Ok(Some(fs)) if lease.check().is_ok() => {
                        match codex_utils_path_uri::PathUri::from_host_native_path(path) {
                            Ok(uri) => fs.read_file(&uri, Default::default(), None).await.and_then(
                                |bytes| {
                                    lease.check()?;
                                    Ok(bytes)
                                },
                            ),
                            Err(_) => Err(denied()),
                        }
                    }
                    _ => Err(denied()),
                };
                reads.push_back(result);
            }
            ResponseInputItem::from_user_input_with_local_media_reader(
                input,
                LocalImagePreparation::Defer,
                |_| {
                    lease.check()?;
                    reads.pop_front().unwrap_or_else(|| Err(denied()))
                },
            )
        }
    }
}
impl std::fmt::Debug for CapturedTurnLease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Legacy => "Legacy",
            Self::Denied => "Denied",
            Self::Bound(_) => "BoundTurnLease",
        })
    }
}

/// Trusted embedding scopes a single RPC submission future with an immutable
/// admission permit. Tokio tasks/child turns do not inherit task-local permits.
pub type SubmissionAdmission = dyn Fn(&str, &str) -> io::Result<()> + Send + Sync;
tokio::task_local! { static SUBMISSION_ADMISSION: Arc<SubmissionAdmission>; }
pub async fn with_submission_admission<F: std::future::Future>(
    permit: Arc<SubmissionAdmission>,
    future: F,
) -> F::Output {
    SUBMISSION_ADMISSION.scope(permit, future).await
}
pub(crate) fn admit_submission(thread: &str, submission: &str) -> io::Result<()> {
    SUBMISSION_ADMISSION
        .try_with(|permit| permit(thread, submission))
        .unwrap_or(Ok(()))
}

/// Real AppServer queues initialized requests into separate Tokio tasks. Only
/// its trusted TurnStart queue entry may capture and re-scope this permit.
/// Child/review/resume RPCs and Session-created tasks never inherit it.
pub fn current_submission_admission() -> Option<Arc<SubmissionAdmission>> {
    SUBMISSION_ADMISSION.try_with(Arc::clone).ok()
}
pub async fn with_optional_submission_admission<F: std::future::Future>(
    permit: Option<Arc<SubmissionAdmission>>,
    future: F,
) -> F::Output {
    match permit {
        Some(permit) => with_submission_admission(permit, future).await,
        None => future.await,
    }
}
