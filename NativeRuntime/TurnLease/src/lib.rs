//! Immutable trusted turn authority. No model-input or pathname grant factory.
use std::io;
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};

pub const DENIAL: &str = "operation denied by turn workspace capability; use a permitted workspace file or the trusted application workflow";
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub thread: String,
    pub turn: String,
    pub generation: u64,
}
pub struct CapturedLease<T: ?Sized> {
    identity: Identity,
    authority: Arc<T>,
    live: AtomicBool,
    revoke: Arc<dyn Fn() -> io::Result<()> + Send + Sync>,
    revoked: Mutex<bool>,
}
impl<T: ?Sized> CapturedLease<T> {
    /// Trusted caller binds immutable identity and an already scoped authority.
    /// Revoke callback must invalidate that authority, serialize with final I/O,
    /// and never reopen a pathname or create a replacement grant.
    pub fn new(identity: Identity, authority: Arc<T>, revoke: Arc<dyn Fn() -> io::Result<()> + Send + Sync>) -> io::Result<Self> {
        if identity.thread.is_empty() || identity.turn.is_empty() || identity.generation == 0 {
            return Err(denied());
        }
        Ok(Self { identity, authority, live: AtomicBool::new(true), revoke, revoked: Mutex::new(false) })
    }
    pub fn identity(&self) -> &Identity { &self.identity }
    pub fn check(&self) -> io::Result<()> {
        if self.live.load(Ordering::Acquire) { Ok(()) } else { Err(denied()) }
    }
    pub fn authority(&self) -> io::Result<Arc<T>> {
        self.check()?;
        Ok(Arc::clone(&self.authority))
    }
    pub fn matches(&self, thread: &str, turn: &str) -> bool {
        self.identity.thread == thread && self.identity.turn == turn
    }
    pub fn revoke(&self) -> io::Result<()> {
        // Every caller waits for completed underlying revocation. A cached Arc
        // is safe only when its actual filesystem enforces the revoked grant.
        let mut completed = self.revoked.lock().map_err(|_| denied())?;
        if *completed { return Ok(()); }
        self.live.store(false, Ordering::Release);
        (self.revoke)().map_err(|_| denied())?;
        *completed = true;
        Ok(())
    }
}
pub fn denied() -> io::Error { io::Error::new(io::ErrorKind::PermissionDenied, DENIAL) }

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    #[test]
    fn retained_old_lease_never_becomes_next_turn_authority() {
        let calls = Arc::new(AtomicUsize::new(0));
        let count = calls.clone();
        let a = Arc::new(CapturedLease::new(Identity { thread:"t".into(), turn:"a".into(), generation:1 }, Arc::new(10), Arc::new(move || {count.fetch_add(1,Ordering::SeqCst); Ok(())})).unwrap());
        let retained = a.clone();
        a.revoke().unwrap(); a.revoke().unwrap();
        let b = CapturedLease::new(Identity { thread:"t".into(), turn:"b".into(), generation:2 }, Arc::new(20), Arc::new(|| Ok(()))).unwrap();
        assert!(retained.authority().is_err());
        assert!(!retained.matches("t","b"));
        assert_eq!(*b.authority().unwrap(),20);
        assert_eq!(calls.load(Ordering::SeqCst),1);
        assert_eq!(retained.check().unwrap_err().to_string(),DENIAL);
    }
    #[test]
    fn concurrent_revoke_waits_for_actual_callback_completion() {
        let (started_tx,started_rx)=std::sync::mpsc::channel();
        let (release_tx,release_rx)=std::sync::mpsc::channel();
        let release=Mutex::new(release_rx);
        let lease=Arc::new(CapturedLease::new(Identity {thread:"t".into(),turn:"a".into(),generation:1},Arc::new(()),Arc::new(move || {started_tx.send(()).unwrap(); release.lock().unwrap().recv().unwrap(); Ok(())})).unwrap());
        let first=lease.clone(); let a=std::thread::spawn(move ||first.revoke().unwrap());
        started_rx.recv().unwrap();
        assert!(lease.check().is_err());
        let second=lease.clone(); let (done_tx,done_rx)=std::sync::mpsc::channel();
        let b=std::thread::spawn(move ||{second.revoke().unwrap();done_tx.send(()).unwrap();});
        assert!(done_rx.recv_timeout(std::time::Duration::from_millis(30)).is_err());
        release_tx.send(()).unwrap(); a.join().unwrap(); b.join().unwrap(); done_rx.recv().unwrap();
    }
    #[test]
    fn failed_underlying_revoke_never_confirms_cleanup() {
        let lease=CapturedLease::new(Identity {thread:"t".into(),turn:"a".into(),generation:1},Arc::new(()),Arc::new(||Err(io::Error::other("private detail")))).unwrap();
        assert_eq!(lease.revoke().unwrap_err().to_string(),DENIAL);
        assert!(lease.revoke().is_err());
        assert!(lease.authority().is_err());
    }
    #[test]
    fn invalid_identity_does_not_issue_authority() {
        assert!(CapturedLease::new(Identity {thread:"t".into(),turn:"a".into(),generation:0},Arc::new(()),Arc::new(|| Ok(()))).is_err());
    }
}
