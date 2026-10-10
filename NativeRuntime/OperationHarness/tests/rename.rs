use hyotan_operation_harness::{
    Access, FileAccess, Harness, MAX_RECURSIVE_DEPTH, MAX_RECURSIVE_ENTRIES, OpenOptions, Scope,
};
use std::{
    fs, io,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};
static SERIAL: AtomicUsize = AtomicUsize::new(0);
struct Fixture {
    base: PathBuf,
    work: PathBuf,
    private: PathBuf,
    h: Harness,
    s: Scope,
}
impl Fixture {
    fn new() -> Self {
        let base = std::env::temp_dir().join(format!(
            "hyotan-rename-{}-{}",
            std::process::id(),
            SERIAL.fetch_add(1, Ordering::Relaxed)
        ));
        let work = base.join("work");
        let private = base.join("private");
        fs::create_dir_all(&work).unwrap();
        fs::create_dir(&private).unwrap();
        fs::write(private.join("canary"), b"private").unwrap();
        Self {
            base,
            work,
            private,
            h: Harness::default(),
            s: Scope {
                owner: "rename".into(),
                generation: 1,
            },
        }
    }
    fn cap(&self, a: Access) -> hyotan_operation_harness::Capability {
        self.h.grant(&self.work, self.s.clone(), a).unwrap()
    }
    fn unchanged(&self) {
        assert_eq!(fs::read(self.private.join("canary")).unwrap(), b"private");
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.base).unwrap();
    }
}
fn deny(r: io::Result<()>) {
    let e = r.unwrap_err();
    assert_eq!(e.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(e.to_string(), "operation denied");
}
#[test]
fn atomic_replacement_keeps_both_open_objects_and_unlinked_handles() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    fs::write(f.work.join("一時"), b"new").unwrap();
    fs::write(f.work.join("公開"), b"old").unwrap();
    let rw = OpenOptions {
        access: FileAccess::ReadWrite,
        create: false,
        exclusive: false,
        truncate: false,
        append: false,
    };
    let source = f.h.open_handle(c, &f.s, Path::new("一時"), rw).unwrap();
    let old = f.h.open_handle(c, &f.s, Path::new("公開"), rw).unwrap();
    f.h.rename(c, &f.s, Path::new("一時"), Path::new("公開"))
        .unwrap();
    assert_eq!(f.h.read_at(c, &f.s, source, 0, 3).unwrap(), b"new");
    assert_eq!(f.h.read_at(c, &f.s, old, 0, 3).unwrap(), b"old");
    f.h.write_at(c, &f.s, old, 0, b"OLD").unwrap();
    f.h.truncate_handle(c, &f.s, old, 2).unwrap();
    assert_eq!(f.h.stat_handle(c, &f.s, old).unwrap().bytes, 2);
    assert_eq!(f.h.read_at(c, &f.s, old, 0, 3).unwrap(), b"OL");
    assert_eq!(fs::read(f.work.join("公開")).unwrap(), b"new");
    f.h.remove(c, &f.s, Path::new("公開"), false).unwrap();
    assert_eq!(f.h.read_at(c, &f.s, source, 0, 3).unwrap(), b"new");
    f.h.close_handle(c, &f.s, old).unwrap();
    f.h.close_handle(c, &f.s, source).unwrap();
    f.unchanged();
}
#[test]
fn directories_types_same_path_and_rejected_moves_leave_namespace_intact() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    fs::create_dir(f.work.join("dir")).unwrap();
    fs::write(f.work.join("dir/child"), b"child").unwrap();
    fs::create_dir(f.work.join("empty")).unwrap();
    f.h.rename(c, &f.s, Path::new("dir"), Path::new("empty"))
        .unwrap();
    assert_eq!(fs::read(f.work.join("empty/child")).unwrap(), b"child");
    f.h.rename(c, &f.s, Path::new("empty"), Path::new("empty"))
        .unwrap();
    fs::create_dir(f.work.join("full")).unwrap();
    fs::write(f.work.join("full/keep"), b"keep").unwrap();
    fs::write(f.work.join("file"), b"file").unwrap();
    for (src, dst, kind) in [
        ("empty", "full", io::ErrorKind::DirectoryNotEmpty),
        ("file", "empty", io::ErrorKind::IsADirectory),
        ("empty", "file", io::ErrorKind::NotADirectory),
        ("empty", "empty/sub", io::ErrorKind::InvalidInput),
    ] {
        let e =
            f.h.rename(c, &f.s, Path::new(src), Path::new(dst))
                .unwrap_err();
        assert_eq!(e.kind(), kind);
        assert_eq!(e.to_string(), "operation failed");
    }
    assert_eq!(fs::read(f.work.join("empty/child")).unwrap(), b"child");
    assert_eq!(fs::read(f.work.join("full/keep")).unwrap(), b"keep");
    assert_eq!(fs::read(f.work.join("file")).unwrap(), b"file");
}
#[test]
fn both_paths_scope_permissions_links_and_subtree_budgets_are_checked_before_mutation() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let ro = f.cap(Access::ReadOnly);
    fs::write(f.work.join("source"), b"safe").unwrap();
    symlink(f.private.join("canary"), f.work.join("link")).unwrap();
    symlink(&f.private, f.work.join("ancestor")).unwrap();
    fs::hard_link(f.private.join("canary"), f.work.join("hard")).unwrap();
    let fifo = std::ffi::CString::new(f.work.join("fifo").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    for bad in [
        "../private/canary",
        "/private/canary",
        "bad\0name",
        ".",
        "",
        "link",
        "hard",
        "fifo",
        "ancestor/canary",
    ] {
        deny(f.h.rename(c, &f.s, Path::new("source"), Path::new(bad)));
        deny(f.h.rename(c, &f.s, Path::new(bad), Path::new("source")));
    }
    deny(f.h.rename(ro, &f.s, Path::new("source"), Path::new("later")));
    let wrong = Scope {
        owner: "other".into(),
        generation: 1,
    };
    deny(f.h.rename(c, &wrong, Path::new("source"), Path::new("later")));
    let wrong = Scope {
        owner: f.s.owner.clone(),
        generation: 2,
    };
    deny(f.h.rename(c, &wrong, Path::new("source"), Path::new("later")));
    fs::create_dir(f.work.join("protected")).unwrap();
    fs::write(f.work.join("protected/normal"), b"stay").unwrap();
    symlink(f.private.join("canary"), f.work.join("protected/link")).unwrap();
    deny(f.h.rename(c, &f.s, Path::new("protected"), Path::new("moved")));
    assert!(f.work.join("protected/normal").exists());
    assert!(!f.work.join("moved").exists());
    fs::create_dir(f.work.join("deep")).unwrap();
    let mut path = f.work.join("deep");
    for _ in 0..=MAX_RECURSIVE_DEPTH {
        path.push("d");
        fs::create_dir(&path).unwrap();
    }
    deny(f.h.rename(c, &f.s, Path::new("deep"), Path::new("deep-moved")));
    assert!(path.exists());
    assert!(!f.work.join("deep-moved").exists());
    fs::create_dir(f.work.join("wide")).unwrap();
    for n in 0..MAX_RECURSIVE_ENTRIES {
        fs::write(f.work.join("wide").join(n.to_string()), b"").unwrap();
    }
    deny(f.h.rename(c, &f.s, Path::new("wide"), Path::new("wide-moved")));
    assert!(f.work.join("wide").exists());
    assert!(!f.work.join("wide-moved").exists());
    f.h.revoke(c, &f.s).unwrap();
    deny(f.h.rename(c, &f.s, Path::new("source"), Path::new("later")));
    let next = f.cap(Access::ReadWrite);
    f.h.rename(next, &f.s, Path::new("source"), Path::new("later"))
        .unwrap();
    f.unchanged();
}
#[test]
fn publication_readers_only_observe_complete_old_or_new_files() {
    let f = Fixture::new();
    let c = f.cap(Access::ReadWrite);
    let first = vec![b'a'; 65536];
    let second = vec![b'b'; 65536];
    fs::write(f.work.join("published"), &first).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let ready = Arc::new(AtomicUsize::new(0));
    let work = f.work.clone();
    let done = stop.clone();
    let seen = ready.clone();
    let reader = std::thread::spawn(move || {
        while !done.load(Ordering::Acquire) {
            let bytes = fs::read(work.join("published")).unwrap();
            assert_eq!(bytes.len(), 65536);
            assert!(bytes.iter().all(|b| *b == bytes[0]));
            assert!(bytes[0] == b'a' || bytes[0] == b'b');
            seen.fetch_add(1, Ordering::Release);
        }
    });
    while ready.load(Ordering::Acquire) < 5 {
        std::thread::yield_now();
    }
    for n in 0..100 {
        f.h.write(
            c,
            &f.s,
            Path::new("temporary"),
            if n % 2 == 0 { &second } else { &first },
        )
        .unwrap();
        f.h.rename(c, &f.s, Path::new("temporary"), Path::new("published"))
            .unwrap();
    }
    stop.store(true, Ordering::Release);
    reader.join().unwrap();
    assert!(ready.load(Ordering::Acquire) >= 5);
}
